var VISIT_TYPES = { service: true, pickup: true, delivery: true };

var COMPARE_ROWS = [
  { key: 'solvers', kind: 'text' },
  { key: 'interpreters', kind: 'text' },
  { key: 'heuristics', kind: 'text' },
  { key: 'elapsed', kind: 'elapsed_ms', higherIsWorse: true },
  { key: 'iterations', kind: 'count' },
  { key: 'unassigned', kind: 'count', higherIsWorse: true },
  { key: 'unassigned_reasons', kind: 'text' },
  { key: 'distance', kind: 'km', higherIsWorse: true },
  { key: 'tour', kind: 'duration', higherIsWorse: true },
  { key: 'work', kind: 'duration', higherIsWorse: true },
  { key: 'stops', kind: 'count', higherIsWorse: true },
  { key: 'visits', kind: 'duration', higherIsWorse: true },
  { key: 'pauses', kind: 'duration', higherIsWorse: true },
  { key: 'driving', kind: 'duration', higherIsWorse: true },
  { key: 'waiting', kind: 'duration', higherIsWorse: true },
  { key: 'vehicles', kind: 'count', higherIsWorse: true },
  { key: 'cost', kind: 'money', higherIsWorse: true }
];

function compareField(object, name) {
  if (!object || object[name] == null || object[name] === '') return null;
  var value = Number(object[name]);
  return isNaN(value) ? null : value;
}

function activityDuration(activity) {
  var detail = activity.detail || {};
  if (detail.duration != null && detail.duration !== '') return Number(detail.duration) || 0;
  if (activity.end_time != null && activity.begin_time != null) {
    return Math.max(0, Number(activity.end_time) - Number(activity.begin_time));
  }
  return 0;
}

function isVisit(activity) {
  if (VISIT_TYPES[activity.type]) return true;
  return !!(activity.service_id || activity.pickup_shipment_id || activity.delivery_shipment_id);
}

function isPause(activity) {
  return activity.type === 'rest' || !!activity.rest_id;
}

function listField(value) {
  if (Array.isArray(value)) {
    var parts = value.filter(function (item) { return item != null && item !== ''; });
    return parts.length ? parts.join(', ') : null;
  }
  if (value == null || value === '') return null;
  return String(value);
}

function heuristicNames(synthesis) {
  if (!Array.isArray(synthesis) || !synthesis.length) return null;
  var names = synthesis.map(function (item) {
    if (!item || typeof item !== 'object') return item;
    return item.heuristic || item.name || item.strategy || null;
  }).filter(Boolean);
  return names.length ? names.join(', ') : null;
}

function groupUnassignedReasons(solution) {
  var unassigned = (solution && (solution.unassigned || solution.unassigned_stops)) || [];
  if (!unassigned.length) return { count: 0, reasons: null };

  var counts = {};
  unassigned.forEach(function (stop) {
    var reason = (stop && stop.reason) || 'unknown';
    counts[reason] = (counts[reason] || 0) + 1;
  });

  var reasons = Object.keys(counts).sort(function (a, b) {
    return counts[b] - counts[a] || a.localeCompare(b);
  }).map(function (reason) {
    return reason + ' (' + counts[reason] + ')';
  }).join(', ');

  return { count: unassigned.length, reasons: reasons };
}

function compareStats(solution) {
  var routes = (solution && solution.routes) || [];
  var visits = 0;
  var visitDuration = 0;
  var pauseDuration = 0;
  var vehicles = 0;
  var tourFromClock = 0;
  var clockComplete = routes.length > 0;

  routes.forEach(function (route) {
    var activities = route.activities || route.stops || [];
    var routeVisits = 0;
    activities.forEach(function (activity) {
      if (isPause(activity)) {
        pauseDuration += activityDuration(activity);
        return;
      }
      if (!isVisit(activity)) return;
      routeVisits += 1;
      visitDuration += activityDuration(activity);
    });
    visits += routeVisits;
    if (routeVisits > 0) vehicles += 1;
    if (route.start_time == null || route.end_time == null) clockComplete = false;
    else tourFromClock += Number(route.end_time) - Number(route.start_time);
  });

  var driving = compareField(solution, 'total_travel_time');
  var cost = compareField(solution, 'cost');
  var unassigned = groupUnassignedReasons(solution);

  return {
    solvers: listField(solution && solution.solvers),
    interpreters: listField(solution && solution.interpreters),
    heuristics: heuristicNames(solution && solution.heuristic_synthesis),
    elapsed: compareField(solution, 'elapsed'),
    iterations: compareField(solution, 'iterations'),
    unassigned: unassigned.count,
    unassigned_reasons: unassigned.reasons,
    distance: compareField(solution, 'total_distance'),
    tour: clockComplete ? tourFromClock : compareField(solution, 'total_time'),
    work: (driving || 0) + visitDuration,
    stops: visits,
    visits: visitDuration,
    pauses: pauseDuration,
    driving: driving,
    waiting: compareField(solution, 'total_waiting_time'),
    vehicles: vehicles,
    cost: cost
  };
}

function formatDuration(seconds) {
  if (seconds == null || isNaN(seconds)) return '\u2014';
  var sign = seconds < 0 ? '-' : '';
  var abs = Math.abs(Math.round(seconds));
  var hours = Math.floor(abs / 3600);
  var minutes = Math.floor((abs % 3600) / 60);
  var hh = hours < 10 ? '0' + hours : String(hours);
  var mm = minutes < 10 ? '0' + minutes : String(minutes);
  return sign + hh + ':' + mm;
}

function formatNumber(value, digits) {
  return new Intl.NumberFormat('fr-FR', {
    useGrouping: false,
    minimumFractionDigits: digits,
    maximumFractionDigits: digits
  }).format(value);
}

function formatKm(meters) {
  if (meters == null || isNaN(meters)) return '\u2014';
  var km = meters / 1000;
  var digits = Math.abs(km - Math.round(km)) < 0.05 ? 0 : 1;
  return formatNumber(km, digits) + ' km';
}

function formatMoney(value) {
  if (value == null || isNaN(value)) return '\u2014';
  return formatNumber(value, 2);
}

function formatCount(value) {
  if (value == null || isNaN(value)) return '\u2014';
  return String(value);
}

function formatElapsedMs(ms) {
  if (ms == null || isNaN(ms)) return '\u2014';
  var seconds = ms / 1000;
  if (Math.abs(seconds) < 60) return formatNumber(seconds, 1) + ' s';
  return formatDuration(seconds);
}

function formatStat(kind, value) {
  if (kind === 'text') return value == null || value === '' ? '\u2014' : String(value);
  if (kind === 'km') return formatKm(value);
  if (kind === 'duration') return formatDuration(value);
  if (kind === 'elapsed_ms') return formatElapsedMs(value);
  if (kind === 'money') return formatMoney(value);
  return formatCount(value);
}

function formatDelta(kind, delta) {
  if (delta == null || delta === 0) return '\u2014';
  var sign = delta > 0 ? '+' : '-';
  var abs = Math.abs(delta);
  if (kind === 'duration') return sign + formatDuration(abs);
  if (kind === 'elapsed_ms') return sign + formatElapsedMs(abs);
  if (kind === 'km') return sign + formatKm(abs);
  if (kind === 'money') return sign + formatMoney(abs);
  return sign + formatCount(abs);
}

function deltaTone(row, value, reference) {
  if (value == null || reference == null || value === reference) return 'same';
  if (row.kind === 'text' || row.higherIsWorse == null) return 'diff';
  var worse = row.higherIsWorse ? value > reference : value < reference;
  return worse ? 'worse' : 'better';
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, function (char) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char];
  });
}

function compareLabel(key) {
  if (typeof i18next !== 'undefined') return i18next.t('compare_' + key);
  return key;
}

var planCompareState = {
  plans: [],
  referenceId: null,
  knownJobs: []
};

function planById(jobId) {
  for (var i = 0; i < planCompareState.plans.length; i++) {
    if (planCompareState.plans[i].id === jobId) return planCompareState.plans[i];
  }
  return null;
}

function renderCompare() {
  var wrap = document.getElementById('compare-table-wrap');
  if (!wrap) return;
  if (planCompareState.plans.length === 0) {
    wrap.innerHTML = '';
    return;
  }

  var reference = planById(planCompareState.referenceId) || planCompareState.plans[0];
  planCompareState.referenceId = reference.id;

  var head = '<th class="compare-indicator">' + escapeHtml(compareLabel('indicator')) + '</th>';
  planCompareState.plans.forEach(function (plan) {
    var checked = plan.id === planCompareState.referenceId ? ' checked' : '';
    head += '<th class="compare-plan' + (checked ? ' is-reference' : '') + '">'
      + '<div class="plan-head">'
      + '<button type="button" class="plan-close" data-remove="' + escapeHtml(plan.id) + '" aria-label="'
      + escapeHtml(compareLabel('remove')) + '">\u00d7</button>'
      + '<div class="plan-title" title="' + escapeHtml(plan.id) + '">' + escapeHtml(plan.label) + '</div>'
      + (plan.when ? '<div class="plan-when">' + escapeHtml(plan.when) + '</div>' : '')
      + '<label class="plan-ref"><input type="radio" name="compare-reference" data-reference="'
      + escapeHtml(plan.id) + '"' + checked + '> '
      + escapeHtml(compareLabel('reference')) + '</label>'
      + '</div></th>';
  });

  var body = COMPARE_ROWS.map(function (row) {
    var cells = '<th>' + escapeHtml(compareLabel(row.key)) + '</th>';
    planCompareState.plans.forEach(function (plan) {
      var value = plan.stats ? plan.stats[row.key] : null;
      var refValue = reference.stats ? reference.stats[row.key] : null;
      var isReference = plan.id === reference.id;
      var tone = isReference ? 'same' : deltaTone(row, value, refValue);
      var delta = '\u2014';
      if (!isReference && row.kind !== 'text' && value != null && refValue != null && value !== refValue) {
        delta = formatDelta(row.kind, value - refValue);
      }
      cells += '<td class="metric-cell tone-' + tone + (isReference ? ' is-reference' : '') + '">'
        + '<div class="metric">' + escapeHtml(formatStat(row.kind, value)) + '</div>'
        + (row.kind === 'text' ? '' : '<div class="delta">' + escapeHtml(delta) + '</div>')
        + '</td>';
    });
    return '<tr>' + cells + '</tr>';
  }).join('');

  wrap.innerHTML = '<div class="compare-scroll"><table class="compare-table"><thead><tr>'
    + head + '</tr></thead><tbody>' + body + '</tbody></table></div>';
}

function showCompareError(message) {
  var node = document.getElementById('compare-error');
  if (!node) return;
  if (!message) {
    node.hidden = true;
    node.textContent = '';
    return;
  }
  node.hidden = false;
  node.textContent = message;
}

function addPlan(jobId, meta) {
  jobId = (jobId || '').trim();
  if (!jobId) return;
  if (planById(jobId)) {
    renderCompare();
    return;
  }
  showCompareError('');
  var plan = {
    id: jobId,
    label: jobId,
    when: meta && meta.when,
    stats: null
  };
  planCompareState.plans.push(plan);
  if (!planCompareState.referenceId) planCompareState.referenceId = jobId;
  renderCompare();

  $.ajax({
    url: '/0.1/vrp/jobs/' + encodeURIComponent(jobId) + '.json',
    type: 'get',
    dataType: 'json',
    data: { api_key: getParams()['api_key'] }
  }).done(function (data) {
    var solution = data.solutions && data.solutions[0];
    if (!solution) {
      planCompareState.plans = planCompareState.plans.filter(function (item) { return item.id !== jobId; });
      if (planCompareState.referenceId === jobId) {
        planCompareState.referenceId = planCompareState.plans[0] && planCompareState.plans[0].id;
      }
      showCompareError(compareLabel('no_solution'));
      renderCompare();
      return;
    }
    plan.stats = compareStats(solution);
    if (solution.name) plan.label = solution.name;
    if (data.job && data.job.avancement && !plan.when) plan.when = data.job.avancement;
    renderCompare();
  }).fail(function (jqXHR) {
    planCompareState.plans = planCompareState.plans.filter(function (item) { return item.id !== jobId; });
    if (planCompareState.referenceId === jobId) {
      planCompareState.referenceId = planCompareState.plans[0] && planCompareState.plans[0].id;
    }
    var message = jqXHR.responseJSON && jqXHR.responseJSON.message;
    showCompareError(message || i18next.t('compare_missing', { id: jobId }));
    renderCompare();
  });
}

function syncJobs(jobs) {
  planCompareState.knownJobs = jobs || [];
  var list = document.getElementById('compare-job-ids');
  if (!list) return;
  list.innerHTML = '';
  planCompareState.knownJobs.forEach(function (job) {
    if (job.status !== 'completed') return;
    var option = document.createElement('option');
    option.value = job.uuid;
    list.appendChild(option);
  });
}

function initCompare() {
  var form = document.getElementById('compare-add');
  if (!form) return;
  document.getElementById('compare-title').textContent = compareLabel('title');
  document.getElementById('compare-help').textContent = compareLabel('help');
  document.getElementById('compare-job-id').placeholder = compareLabel('add_placeholder');
  document.getElementById('compare-submit').textContent = compareLabel('add');

  form.addEventListener('submit', function (event) {
    event.preventDefault();
    var input = document.getElementById('compare-job-id');
    addPlan(input.value);
    input.value = '';
  });

  document.getElementById('compare-table-wrap').addEventListener('click', function (event) {
    var removeId = event.target.getAttribute('data-remove');
    if (!removeId) return;
    planCompareState.plans = planCompareState.plans.filter(function (plan) { return plan.id !== removeId; });
    if (planCompareState.referenceId === removeId) {
      planCompareState.referenceId = planCompareState.plans[0] && planCompareState.plans[0].id;
    }
    renderCompare();
  });

  document.getElementById('compare-table-wrap').addEventListener('change', function (event) {
    var referenceId = event.target.getAttribute('data-reference');
    if (!referenceId) return;
    planCompareState.referenceId = referenceId;
    renderCompare();
  });
}

if (typeof window !== 'undefined') {
  window.planCompare = {
    add: addPlan,
    syncJobs: syncJobs
  };
  if (typeof $ !== 'undefined') $(initCompare);
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    compareStats: compareStats,
    groupUnassignedReasons: groupUnassignedReasons,
    formatDuration: formatDuration,
    formatElapsedMs: formatElapsedMs,
    formatKm: formatKm,
    formatMoney: formatMoney,
    formatDelta: formatDelta,
    deltaTone: deltaTone
  };
}
