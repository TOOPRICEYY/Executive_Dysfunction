// Exercise the actual inline script without a live filter or browser session.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('Sources/BlockPageShared/BlockPageTypingGuard.swift', 'utf8');
const script = source.match(/static let script = """\n([\s\S]*?)\n    """/)[1];
const listeners = {};
const field = { value: '', addEventListener: (type, callback) => { listeners[type] = callback; } };
const buttons = [{ disabled: true }];
let submit;
let selectedIntent = null;
let intentChanged;
const radios = [{ addEventListener: (_, callback) => { intentChanged = callback; } }];
const form = {
  querySelector: selector => selector === 'textarea' ? field : selectedIntent,
  querySelectorAll: selector => selector.includes('intent') ? radios : buttons,
  addEventListener: (_, callback) => { submit = callback; }
};
vm.runInNewContext(script, { document: { querySelectorAll: () => [form] } });
function event(values = {}) {
  return { isTrusted: true, prevented: false, preventDefault() { this.prevented = true; }, ...values };
}
assert.equal(buttons[0].disabled, true);
for (const type of ['paste', 'drop']) {
  const attempt = event(); listeners[type](attempt); assert.equal(attempt.prevented, true);
}
const key = event({ inputType: 'insertText', data: 'a' });
listeners.beforeinput(key); assert.equal(key.prevented, false);
field.value = 'a'; listeners.input(key); assert.equal(buttons[0].disabled, true);
const noIntent = event(); submit(noIntent); assert.equal(noIntent.prevented, true);
selectedIntent = { value: 'consciousIntervention' }; intentChanged();
assert.equal(buttons[0].disabled, false);
selectedIntent = { value: 'eDulgance' }; intentChanged();
const withIntent = event(); submit(withIntent); assert.equal(withIntent.prevented, false);
const bulk = event({ inputType: 'insertFromPaste', data: 'copied answer' });
listeners.beforeinput(bulk); assert.equal(bulk.prevented, true);
field.value = 'copied answer'; listeners.input(bulk); assert.equal(field.value, 'a');
field.value = 'injected'; listeners.input(event({ isTrusted: false, inputType: 'insertText', data: 'b' }));
assert.equal(field.value, 'a');
field.value = 'injected'; const submission = event(); submit(submission);
assert.equal(submission.prevented, true);
assert.equal(field.value, 'a');
const deletion = event({ inputType: 'deleteContentBackward' });
listeners.beforeinput(deletion); field.value = ''; listeners.input(deletion);
assert.equal(buttons[0].disabled, true);
console.log('PASS: explicit intent selection, typing, deletion, paste, drop, bulk input, synthetic input, and altered submission');
