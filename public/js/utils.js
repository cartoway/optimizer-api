Number.prototype.toHHMMSS = function() {
  var sec_num = parseInt(this, 10); // don't forget the second param
  var hours   = Math.floor(sec_num / 3600);
  var minutes = Math.floor((sec_num - (hours * 3600)) / 60);
  var seconds = sec_num - (hours * 3600) - (minutes * 60);

  if (hours   < 10) {hours   = "0"+hours;}
  if (minutes < 10) {minutes = "0"+minutes;}
  if (seconds < 10) {seconds = "0"+seconds;}
  return hours+':'+minutes+':'+seconds;
};

var displayGraph = function(data) {
  $('#result-graph').show();
  var values = data ? $.map(data, function(v, k) { return {x: v.iteration, y: v.cost}; }) : [];
  if (values && values.length > 0) {
    var ctx = document.getElementById('result-graph').getContext('2d');
    new Chart(ctx).Scatter([{
      label: 'Iterations/Cost',
      data: values
    }], {
      bezierCurve: false
    });
  }
};

var displayTimer = function() {
  var start = new Date();
  return setInterval(function() {
    $('#timer').html(((new Date() - start) / 1000).toHHMMSS());
  }, 1000);
};

var displaySolution = function (jobId, solution, options) {
  var csv = "/0.1/vrp/jobs/" + jobId + '.csv' + '?api_key=' + getParams()['api_key'];
  var summary = '';
  if (typeof solution === 'string') {
    $('#result').html(solution);
  } else if (typeof solution !== 'string') {
    summary = '<span class="optim-summary">iterations: ' + solution.iterations
      + ' cost: <b>' + Math.round(solution.cost) + '</b> (time: '
      + (solution.total_time && solution.total_time.toHHMMSS())
      + ' distance: ' + Math.round(solution.total_distance / 1000) + ')</span>';
    $('#result').html(JSON.stringify(solution, null, 4));
  }

  var jsonData = "data:text/json;charset=utf-8," + encodeURIComponent(JSON.stringify(solution));
  $('#optim-infos').html(summary
    + '<a class="job-action" download="result_' + jobId + '.json" href="' + jsonData + '">' + i18next.t('download_json') + '</a>'
    + '<a class="job-action" download="result_' + jobId + '.csv" href="' + csv + '">' + i18next.t('download_csv') + '</a>'
    + '<a class="job-action" href="/result.html?api_key=' + getParams()['api_key'] + '&job_id=' + encodeURIComponent(jobId)
    + '" target="_blank">' + i18next.t('show_result') + '</a>');

  if (options && options.downloadButton) {
    downloadButton(jobId, csv);
  }
  if (options && options.initForm) {
    initForm();
  } else if (options && options.readyForm) {
    readyForm();
  }
};

// Re-enable submit without clearing the displayed solution / downloads.
var readyForm = function() {
  jobsManager.stopJobChecking();
  if (typeof timer !== 'undefined' && timer) {
    clearInterval(timer);
    timer = null;
  }
  $('#send-files').attr('disabled', false);
};

var initForm = function() {
  readyForm();
  $('#optim-infos').html('');
};
