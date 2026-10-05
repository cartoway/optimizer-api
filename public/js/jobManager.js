
var jobStatusTimeout = null;
var requestPendingAllJobs = false;

function buildDownloadLink(jobId, state) {
  var extension = state === 'failed' ? '.json' : '';
  var msg = state === 'failed'
          ? i18next.t('download_optim_error')
          : i18next.t('download_optim');

  var url = "/0.1/vrp/jobs/" + jobId + extension + '?api_key=' + getParams()['api_key'];

  return '<a class="job-action" download="result_' + jobId + ((extension !== '.json' ? '.csv' : extension))
    + '" href="' + url + '">' + msg + '</a>';
}

function buildResultLink(jobId) {
  return '<a class="job-action" href="/result.html?api_key=' + getParams()['api_key'] + '&job_id=' + encodeURIComponent(jobId) + '" target="_blank">' + i18next.t('show_result') + '</a>'
}

function buildVrpDumpLink(job) {
  if (!job || !job.vrp_dump) return '';
  var jobId = job.uuid;
  var filename = (job.name || jobId) + '.json';
  var url = '/0.1/vrp/jobs/' + encodeURIComponent(jobId) + '/vrp?api_key=' + getParams()['api_key'];
  return '<a class="job-action" download="' + escapeJobHtml(filename) + '" href="' + url + '">'
    + i18next.t('download_vrp') + '</a>';
}

function escapeJobHtml(value) {
  return String(value).replace(/[&<>"']/g, function (char) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char];
  });
}

function nameSegments(name) {
  return String(name || '').split('_').filter(function (segment) { return segment.length > 0; });
}

function jobsMatchingPrefixes(jobs, prefixes) {
  prefixes = prefixes || [];
  return (jobs || []).filter(function (job) {
    var segments = nameSegments(job.name);
    for (var i = 0; i < prefixes.length; i++) {
      if (segments[i] !== prefixes[i]) return false;
    }
    return true;
  });
}

function nextPrefixOptions(jobs, prefixes) {
  var depth = (prefixes || []).length;
  var seen = {};
  var options = [];
  jobsMatchingPrefixes(jobs, prefixes).forEach(function (job) {
    var segment = nameSegments(job.name)[depth];
    if (!segment || seen[segment]) return;
    seen[segment] = true;
    options.push(segment);
  });
  return options.sort();
}

function jobsSignature(jobs) {
  return (jobs || []).map(function (job) {
    return [job.uuid, job.status, job.name || '', job.avancement || '', job.vrp_dump ? '1' : '0'].join('|');
  }).join(';');
}

var jobsManager = {
  jobs: [],
  filterPrefixes: [],
  htmlElements: {
    builder: function (jobs) {
      $('#jobs-list').empty();
      $(jobs).each(function () {

        currentJob = this;
        var donwloadBtn = currentJob.status === 'completed' || currentJob.status === 'failed';
        var startTime = (new Date(currentJob.time)).toLocaleString('fr-FR');
        var completedDate = ''

        if (currentJob.status === 'completed' && currentJob.avancement) {
          var splitedDate = currentJob.avancement
            .replace("Completed at ", '')
            .split(' ');

          completedDate = ' ' + (new Date(`${splitedDate[0]}T${splitedDate[1]}${splitedDate[2]}`)).toLocaleString('fr-FR');
        }


        var jobId = escapeJobHtml(currentJob.uuid);
        var status = escapeJobHtml(currentJob.status);
        var displayName = escapeJobHtml(currentJob.name || currentJob.uuid);
        var compareBtn = currentJob.status === 'completed'
          ? '<button type="button" class="job-action" data-role="compare" value="' + jobId + '">' + i18next.t('compare_action') + '</button>'
          : '';
        var jobDOM =
          '<article class="job-card">'
          + '<div class="job-card-main">'
          + '<time class="optim-start">' + escapeJobHtml(startTime) + '</time>'
          + '<code class="job_title" title="' + jobId + '">' + displayName + '</code>'
          + '<span class="status-pill status-' + status + '">' + i18next.t('status_' + currentJob.status) + '</span>'
          + (completedDate ? '<span class="job-when">' + escapeJobHtml(completedDate.trim()) + '</span>' : '')
          + '</div>'
          + '<div class="job-card-actions">'
          + compareBtn
          + buildVrpDumpLink(currentJob)
          + (donwloadBtn ? buildDownloadLink(currentJob.uuid, currentJob.status) : '')
          + (currentJob.status === 'completed' ? buildResultLink(currentJob.uuid) : '')
          + '<button type="button" class="job-action job-action-danger" data-role="delete" value="' + jobId + '">'
          + ((currentJob.status === 'queued' || currentJob.status === 'working') ? i18next.t('kill_optim') : i18next.t('delete'))
          + '</button>'
          + '</div>'
          + '</article>';

        $('#jobs-list').append(jobDOM);

      });
      $('#jobs-list button').off('click').on('click', function () {
        jobsManager.roleDispatcher(this);
      });
    }
  },
  pruneFilterPrefixes: function () {
    while (jobsManager.filterPrefixes.length > 0) {
      var prefixes = jobsManager.filterPrefixes.slice(0, -1);
      var options = nextPrefixOptions(jobsManager.jobs, prefixes);
      var selected = jobsManager.filterPrefixes[jobsManager.filterPrefixes.length - 1];
      if (options.indexOf(selected) !== -1) break;
      jobsManager.filterPrefixes.pop();
    }
  },
  renderFilters: function () {
    var root = document.getElementById('jobs-filters');
    if (!root) return;

    jobsManager.pruneFilterPrefixes();
    var firstOptions = nextPrefixOptions(jobsManager.jobs, []);
    if (firstOptions.length === 0) {
      root.hidden = true;
      root.innerHTML = '';
      return;
    }

    root.hidden = false;
    var html = '<span class="jobs-filters-label">' + escapeJobHtml(i18next.t('jobs_filter_label')) + '</span>';
    var depth = 0;
    while (true) {
      var prefixes = jobsManager.filterPrefixes.slice(0, depth);
      var options = nextPrefixOptions(jobsManager.jobs, prefixes);
      if (options.length === 0) break;

      var selected = jobsManager.filterPrefixes[depth] || '';
      html += '<select class="jobs-filter-select" data-depth="' + depth + '">'
        + '<option value="">' + escapeJobHtml(i18next.t('jobs_filter_all')) + '</option>';
      options.forEach(function (option) {
        html += '<option value="' + escapeJobHtml(option) + '"'
          + (option === selected ? ' selected' : '') + '>'
          + escapeJobHtml(option) + '</option>';
      });
      html += '</select>';

      if (!selected) break;
      depth += 1;
    }

    if (jobsManager.filterPrefixes.length > 0) {
      html += '<button type="button" class="job-action" data-role="reset-filters">'
        + escapeJobHtml(i18next.t('jobs_filter_reset')) + '</button>';
    }

    root.innerHTML = html;
    $(root).find('select').on('change', function () {
      var selectedDepth = Number(this.getAttribute('data-depth'));
      var value = this.value;
      jobsManager.filterPrefixes = jobsManager.filterPrefixes.slice(0, selectedDepth);
      if (value) jobsManager.filterPrefixes.push(value);
      jobsManager.render();
    });
    $(root).find('[data-role="reset-filters"]').on('click', function () {
      jobsManager.filterPrefixes = [];
      jobsManager.render();
    });
  },
  render: function () {
    jobsManager.renderFilters();
    jobsManager.htmlElements.builder(jobsMatchingPrefixes(jobsManager.jobs, jobsManager.filterPrefixes));
  },
  roleDispatcher: function (object) {
    switch ($(object).data('role')) {
    case 'focus':
      //actually in building, create to apply different behavior to the button object restartJob, actually not set. #TODO
      break;
    case 'compare':
      if (window.planCompare) window.planCompare.add($(object).val());
      break;
    case 'delete':
      if (window.confirm(i18next.t('delete_confirm'))) {
        this.ajaxDeleteJob($(object).val());
      }
      break;
    }
  },
  ajaxGetJobs: function (timeinterval) {
    $('#optim-list-legend').text(i18next.t('current_jobs'));
    var ajaxload = function () {
      if (!requestPendingAllJobs) {
        requestPendingAllJobs = true;
        $.ajax({
          url: '/0.1/vrp/jobs',
          type: 'get',
          dataType: 'json',
          data: { api_key: getParams()['api_key'] },
          complete: function () { requestPendingAllJobs = false; }
        }).done(function (data) {
          jobsManager.shouldUpdate(data);
          if (window.planCompare) window.planCompare.syncJobs(data);
        }).fail(function (jqXHR, textStatus, errorThrown) {
          if (jqXHR.status !== 500) {
            clearInterval(window.AjaxGetRequestInterval);
          }
          if (jqXHR.status == 401) {
            $('#optim-list-status').prepend('<div class="error">' + i18next.t('unauthorized_error') + '</div>');
            $('form input, form button').prop('disabled', true);
          }
        });
      }
    };
    if (timeinterval) {
      ajaxload();
      window.AjaxGetRequestInterval = setInterval(ajaxload, 5000);
    } else {
      ajaxload();
    }
  },
  ajaxDeleteJob: function (uuid) {
    $.ajax({
      url: '/0.1/vrp/jobs/' + uuid,
      type: 'delete',
      dataType: 'json',
      data: {
        api_key: getParams()['api_key']
      },
    }).done(function (data) {
      if (debug) { console.log("the uuid has been deleted from the jobs queue & the DB"); }
      jobsManager.jobs = jobsManager.jobs.filter(function (job) { return job.uuid !== uuid; });
      jobsManager.render();
    });
  },
  shouldUpdate: function (data) {
    data = data || [];
    if (jobsSignature(data) === jobsSignature(jobsManager.jobs)) return;
    jobsManager.jobs = data;
    jobsManager.render();
  },
  checkJobStatus: function (options, cb) {
    var nbError = 0;
    var requestPendingJobTimeout = false;

    if (options.interval) {
      jobStatusTimeout = setTimeout(requestPendingJob, options.interval);
      return;
    }

    requestPendingJob();

    function requestPendingJob() {
      $.ajax({
        type: 'GET',
        contentType: 'application/json',
        url: '/0.1/vrp/jobs/'
          + (options.job.id || options.job.uuid)
          // + (options.format ? options.format : '')
          + '.json?api_key=' + getParams()["api_key"],
        success: function (job, _, xhr) {
          if (options.interval && checkJSONJob(job)) {
            if (debug) console.log("REQUEST PENDING JOB", checkJSONJob(job));
            requestPendingJobTimeout = true;
          }

          nbError = 0;
          cb(null, job, xhr);
        },
        error: function (xhr, status) {
          ++nbError
          if (nbError > 2) {
            cb({ xhr, status });
            return alert(i18next.t('failure_optim', { attempts: nbError, error: status}));
          }
          requestPendingJobTimeout = true;
        },
        complete: function () {
          if (requestPendingJobTimeout) {
            requestPendingJobTimeout = false;

            // interval max: 1mins
            options.interval *= 2;
            if (options.interval > 60000) {
              options.interval = 60000
            }

            jobStatusTimeout = setTimeout(requestPendingJob, options.interval);
          }
        }
      });
    }
  },
  stopJobChecking: function () {
    requestPendingJobTimeout = false;
    clearTimeout(jobStatusTimeout);
  },
  submit: function (options) {
    const params = buildParams({
      type: "POST",
      url: "/0.1/vrp/submit.json?api_key=" + getParams()['api_key']
    }, options);
    return $.ajax(params);
  },
  delete: function (jobId) {
    return $.ajax({
      type: 'delete',
      url: '/0.1/vrp/jobs/' + jobId + '.json?api_key=' + getParams()["api_key"]
    }).done(function () { jobsManager.stopJobChecking(); })
      .fail(function (jqXHR, textStatus) { alert(textStatus); });
  },
  getCSV: function (jobId, cb) {
    return $.ajax({
      type: 'get',
      url: '/0.1/vrp/jobs/' + jobId + '.csv?api_key=' + getParams()["api_key"],
      success: function (content) {
        cb(content);
      }
    }).done(function () { jobsManager.stopJobChecking(); })
      .fail(function (jqXHR, textStatus) { alert(textStatus); });
  }
};

function checkJSONJob(job) {
  if (debug) console.log("JOB: ", job, (job.job && job.job.status !== 'completed'));
  return ((job.job && job.job.status !== 'completed'))
}

function buildParams(base, params) {
  return Object
    .keys(params)
    .reduce(function (acc, key) {
      acc[key] = params[key]
      return acc
    }, base);
}

function downloadButton(jobId, content) {
  var a = document.createElement('a');
  a.href = content;
  a.target = '_blank';
  a.download = 'result_' + jobId + '.csv';
  document.body.appendChild(a);
  a.click();
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    nameSegments: nameSegments,
    jobsMatchingPrefixes: jobsMatchingPrefixes,
    nextPrefixOptions: nextPrefixOptions
  };
}
