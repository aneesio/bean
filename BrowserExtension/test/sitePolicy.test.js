const assert = require("node:assert/strict");
const policy = require("../src/sitePolicy.js");
const now = 1_000_000;
const paused = policy.mutate({},"Example.COM.","pause",now);
assert.deepEqual(paused,{"example.com":now + policy.HOUR});
assert.equal(policy.until(paused,"example.com",now),now + policy.HOUR);
assert.equal(policy.until(paused,"mail.example.com",now),null,"temporary pauses have exact-host scope");
assert.equal(policy.until({},"constructor",now),null,"prototype names are not paused hosts");
assert.equal(policy.until(paused,"example.com",now + policy.HOUR),null,"expiry automatically resumes assistance");
assert.deepEqual(policy.mutate(paused,"example.com","resume",now),{});
assert.deepEqual(policy.normalize({"example.com":now - 1},now),{},"expired records are pruned before saving");
for (const raw of [null,[],{"https://example.com":now + 1},{"example.com":"123"},{"example.com":Infinity},{"example.com":-1}]) {
  assert.equal(policy.normalize(raw,now),null,"corrupt privacy preferences fail closed");
}
for (const host of ["https://example.com","*.example.com","a..com","a@b.com","private text","a/b"]) {
  assert.equal(policy.mutate({},host,"pause",now),null);
}
const full = Object.fromEntries(Array.from({length:policy.MAX_SITES},(_,i) => [`s${i}.example`,now + 1]));
assert.equal(policy.mutate(full,"new.example","pause",now),null);
assert.equal(policy.mutate(full,"constructor","pause",now),null,"inherited object names cannot bypass the storage bound");
assert.ok(policy.mutate(full,"s0.example","pause",now),"renewing an existing pause stays within the bound");
assert.equal(policy.normalize({...full,"overflow.example":now + 1},now),null);
assert.equal(policy.mutate({},"example.com","forever",now),null);
console.log("Browser website pause policy expiry, scope, corruption, and storage-bound tests passed");
