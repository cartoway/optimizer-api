
var jobStatusTimeout = null;
var requestPendingAllJobs = false;

function buildDownloadLink(jobId, state) {
  var extension = state === 'failed' ? '.json' : '';
  var msg = state === 'failed'
          ? 'Télécharger le rapport d\'erreur de l\'optimisation'
          : 'Télécharger le résultat de l\'optimisation';

  var url = "/0.1/vrp/jobs/" + jobId + extension + '?api_key=' + getParams()['api_key'];

  return ' <a download="result'
    + extension !== '.json' ? '.csv' : extension + '"'
    + ' href="' + url + '">' + msg
    + '</a>';
}

var jobsManager = {
  jobs: [],
  htmlElements: {
    builder: function (jobs) {
      $(jobs).each(function () {

        currentJob = this;
        var donwloadBtn = currentJob.status === 'completed' || currentJob.status === 'failed';

        var jobDOM =
          '<div class="job">'
          + '<span class="optim-start">' + (new Date(currentJob.time)).toLocaleString('fr-FR') + ' : </span>'
          + '<span class="job_title">' + 'Job N° <b>' + currentJob.uuid + '</b></span> '
          + '<button value=' + currentJob.uuid + ' data-role="delete">'
          + ((currentJob.status === 'queued' || currentJob.status === 'working') ? i18n.killOptim : i18n.deleteOptim)
          + '</button>'
          + ' (Status: ' + currentJob.status + ')'
          + (donwloadBtn ? buildDownloadLink(currentJob.uuid, currentJob.status) : '')
          + '</div>';

        $('#jobs-list').append(jobDOM);

      });
      $('#jobs-list button').on('click', function () {
        jobsManager.roleDispatcher(this);
      });
    }
  },
  roleDispatcher: function (object) {
    switch ($(object).data('role')) {
      case 'focus':
        //actually in building, create to apply different behavior to the button object restartJob, actually not set. #TODO
        break;
      case 'delete':
        this.ajaxDeleteJob($(object).val());
        break;
    }
  },
  ajaxGetJobs: function (timeinterval) {
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
        }).fail(function (jqXHR, textStatus, errorThrown) {
          if (jqXHR.status !== 500) {
            clearInterval(window.AjaxGetRequestInterval);
          }
          if (jqXHR.status == 401) {
            $('#optim-list-status').prepend('<div class="error">' + i18n.unauthorizedError + '</div>');
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
      $('button[data-role="delete"][value="' + uuid + '"]').fadeOut(500, function () { $(this).closest('.job').remove(); });
    });
  },
  shouldUpdate: function (data) {
    // erase list if no job running
    if (data.length === 0 && jobsManager.jobs.length !== 0) {
      $('#jobs-list').empty();
    }
    //check if chagements occurs in the data api. #TODO, update if more params are needed.
    $(data).each(function (index, object) {
      if (jobsManager.jobs.length > 0) {
        if (object.status != jobsManager.jobs[index].status || jobsManager.jobs.length != data.length) {
          jobsManager.jobs = data;
          $('#jobs-list').empty();
          jobsManager.htmlElements.builder(jobsManager.jobs);
        }
      }
      else {
        jobsManager.jobs = data;
        $('#jobs-list').empty();
        jobsManager.htmlElements.builder(jobsManager.jobs);
      }
    });
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
          + '?api_key=' + getParams()["api_key"],
        success: function (job, _, xhr) {

          if (options.interval && (checkJSONJob(job) || checkCSVJob(xhr))) {
            if (debug) console.log("REQUEST PENDING JOB", checkCSVJob(xhr), checkJSONJob(job));
            requestPendingJobTimeout = true;
          }

          nbError = 0;
          cb(null, job, xhr);
      },
        error: function (xhr, status) {
          ++nbError
          if (nbError > 2) {
            cb({ xhr, status });
            return alert(i18n.failureOptim(nbError, status));
          }
          requestPendingJobTimeout = true;
        },
        complete: function () {
          if (requestPendingJobTimeout) {
            requestPendingJobTimeout = false;

            // interval max: 1mins
            options.interval *= 2;
            if (options.interval > 60000)  {
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
  }
};

function checkCSVJob(xhr) {
  if (debug) console.log(xhr, xhr.status);
  return (xhr.status !== 200 && xhr.status !== 202);
}

function checkJSONJob(job) {
  if (debug) console.log("JOB: ", job, (job.job && job.job.status !== 'completed'));
  return ((job.job && job.job.status !== 'completed') && typeof job !== 'string')
}
