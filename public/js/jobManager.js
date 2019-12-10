
var jobStatusInterval = null;
var requestPendingAllJobs = false;

var jobsManager = {
  jobs: [],
  htmlElements: {
    builder: function (jobs) {
      $(jobs).each(function () {

        currentJob = this;
        var completed = currentJob.status === 'completed' ? true : false;

        $('#jobs-list').append('<div class="job">'
          + '<span class="job_title">' + 'Job N° ' + currentJob.uuid + '</span> '
          + '<button value=' + currentJob.uuid + ' data-role="delete">'
          + ((currentJob.status === 'queued' || currentJob.status === 'working') ? i18n.killOptim : i18n.deleteOptim)
          + '</button>'
          + ' (Status: ' + currentJob.status + ')'
          + (completed ? ' <a data-job-id=' + currentJob.uuid + ' href="#">' + 'Telecharger le resultat de l\'optimisation' + '</a>' : '')
          + '</div>');

        if (completed) {
          $('a[data-job-id="' + currentJob.uuid + '"').on('click', function (e) {
            e.preventDefault();
            jobsManager.checkJobStatus({
              job: currentJob,
            }, function (err, job) {
              if (err) {
                if (debug) console.error(err);
                return alert("An error occured");
              }

              if (typeof job === 'string') {
                $('#result').html(job)
                var a = document.createElement('a');
                a.href = 'data:attachment/csv,' + encodeURIComponent(job);
                a.target = '_blank';
                a.download = 'result.csv';
                document.body.appendChild(a);
                a.click();
              }
              else {
                var solution = job.solutions[0];
                $('#result').html(JSON.stringify(solution, null, 4));
                var a = document.createElement('a');
                a.href = 'data:attachment/json,' + encodeURIComponent(JSON.stringify(solution, null, 4));
                a.target = '_blank';
                a.download = 'result.json';
                document.body.appendChild(a);
                a.click();
              }
            });

          })
        }
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
          clearInterval(window.AjaxGetRequestInterval);
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
      url: '/0.1/vrp/jobs/' + uuid + '.json',
      type: 'delete',
      dataType: 'json',
      data: {
        api_key: getParams()['api_key']
      },
    }).done(function (data) {
      if (debug) { console.log("the uuid have been deleted from the jobs queue & the DB"); }
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
    var pendingRequest = false;

    if (options.interval) {
      jobStatusInterval = setInterval(function () {
        if (!pendingRequest) {
          pendingRequest = true;
          requestPendingJob();
        }
      }, options.interval);
      return;
    }

    requestPendingJob();

    function requestPendingJob() {
      $.ajax({
        type: 'GET',
        contentType: 'application/json',
        url: '/0.1/vrp/jobs/'
          + (options.job.id || options.job.uuid)
          + (options.format ? options.format : '')
          + '?api_key=' + getParams()["api_key"],
        success: function (job, status, xhr) {
          if (options.format === ".csv") {
            nbError = 0;
            onCSVFormat(jobStatusInterval, job, xhr, cb);
          }
          else if (options.format === ".json") {
            nbError = 0;
            onJSONFormat(jobStatusInterval, job, xhr, cb);
          }
          else {
            cb(null, job, xhr);
          }
        },
        error: function (xhr, status) {
          ++nbError
          if (nbError > 2) {
            alert(i18n.failureOptim(nbError, status));
            if (jobStatusInterval) {
              clearInterval(jobStatusInterval);
            }
            cb({ xhr, status });
          }
        },
        complete: function () { pendingRequest = false; }
      });
    }

  },
  stopJobChecking: function () {
    clearInterval(jobStatusInterval);
  }
};

function onCSVFormat(jobStatusInterval, job, xhr, cb) {
  if (xhr.status === 200 || xhr.status === 202 && jobStatusInterval) {
    clearInterval(jobStatusInterval);
  }
  cb(null, job, xhr);
}

function onJSONFormat(jobStatusInterval, job, xhr, cb) {
  if (((job.job && (job.job.status !== 'queued' && job.job.status !== 'working'))
    || typeof job === 'string') && jobStatusInterval) {
    clearInterval(jobStatusInterval);
  }
  cb(null, job, xhr);
}
