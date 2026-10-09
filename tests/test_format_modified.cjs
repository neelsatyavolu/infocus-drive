const { test } = require("node:test");
const assert = require("node:assert/strict");

test("yesterday is the previous calendar day, not any time in the last 48 hours", async () => {
  const { formatModified } = await import("../app/static/format.js");
  const friday9am = new Date(2026, 9, 9, 9, 0, 0);
  const wednesday10pm = new Date(2026, 9, 7, 22, 0, 0);
  const thursday8am = new Date(2026, 9, 8, 8, 0, 0);
  const realNow = Date.now;
  Date.now = () => friday9am.getTime();
  try {
    // 35 hours ago, two calendar days back. Used to say "Yesterday".
    assert.equal(formatModified(wednesday10pm.toISOString()), "2 days ago");
    assert.equal(formatModified(thursday8am.toISOString()), "Yesterday");
  } finally {
    Date.now = realNow;
  }
});
