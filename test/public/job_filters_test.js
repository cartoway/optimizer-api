const assert = require('assert');
const {
  nameSegments, jobsMatchingPrefixes, nextPrefixOptions
} = require('../../public/js/jobManager.js');

const name = 'cart_c352_lundipierre_c98e06a2a5b2ee0f80ddf521f32cef2c';
assert.deepStrictEqual(
  nameSegments(name),
  ['cart', 'c352', 'lundipierre', 'c98e06a2a5b2ee0f80ddf521f32cef2c']
);

const jobs = [
  { uuid: '1', name: 'cart_c352_lundipierre_aaa' },
  { uuid: '2', name: 'cart_c352_mardipierre_bbb' },
  { uuid: '3', name: 'cart_c999_lundipierre_ccc' },
  { uuid: '4', name: 'bike_c352_lundipierre_ddd' },
  { uuid: '5', name: null }
];

assert.deepStrictEqual(nextPrefixOptions(jobs, []), ['bike', 'cart']);
assert.deepStrictEqual(
  jobsMatchingPrefixes(jobs, ['cart']).map((job) => job.uuid),
  ['1', '2', '3']
);
assert.deepStrictEqual(nextPrefixOptions(jobs, ['cart']), ['c352', 'c999']);
assert.deepStrictEqual(
  jobsMatchingPrefixes(jobs, ['cart', 'c352']).map((job) => job.uuid),
  ['1', '2']
);
assert.deepStrictEqual(nextPrefixOptions(jobs, ['cart', 'c352']), ['lundipierre', 'mardipierre']);
assert.deepStrictEqual(
  jobsMatchingPrefixes(jobs, ['cart', 'c352', 'lundipierre']).map((job) => job.uuid),
  ['1']
);

console.log('ok');
