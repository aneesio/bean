const assert = require("node:assert/strict");
const fs = require("node:fs"), path = require("node:path"), vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname,"..","src","ownershipGuard.js"),"utf8");
const policy = fs.readFileSync(path.join(__dirname,"..","src","sitePolicy.js"),"utf8");
function harness({host="mail.example.com",protocol="https:",frame=false} = {}) {
  const messages = [],events = {},windowEvents = {},timers = new Map();
  let storageListener,listener,timer=0,settings={blockedSites:["example.com"]},focused=true;
  const attrs = {},field = {nodeType:1,tagName:"TEXTAREA",type:"textarea",offsetParent:{},disabled:false,readOnly:false,
    getAttribute:(key) => attrs[key] || null,closest:() => null,getBoundingClientRect:() => ({width:400,height:80})};
  for (const name of ["value","innerText","textContent","selectionStart","selectionEnd"])
    Object.defineProperty(field,name,{get:() => { throw new Error(`disabled-site guard read ${name}`); }});
  const document = {activeElement:field,visibilityState:"visible",hasFocus:() => focused,contains:(el) => el===field,
    addEventListener:(key,callback) => { events[key]=callback; }};
  const window = {addEventListener:(key,callback) => { windowEvents[key]=callback; }};
  window.top=frame ? {} : window;
  const chrome={runtime:{id:"bean",lastError:null,onMessage:{addListener:(fn) => {listener=fn;}},
    sendMessage:(message,callback) => {messages.push(message);callback({ok:true});}},
    storage:{local:{get:(_keys,callback) => callback(settings)},onChanged:{addListener:(fn) => {storageListener=fn;}}}};
  vm.runInNewContext(policy + "\n" + source,{window,document,chrome,location:{hostname:host,protocol,pathname:"/editor"},
    Date,Math,setTimeout:(fn) => {const id=++timer;timers.set(id,fn);return id;},clearTimeout:(id) => timers.delete(id)});
  return {messages,events,windowEvents,timers,field,attrs,document,
    focused:(value) => {focused=value;},
    change:(value) => {settings=value;storageListener({blockedSites:{newValue:settings.blockedSites}},"local");},
    challenge:(token,sender="bean") => {let response;listener({type:"revalidateFieldOwnership",fieldToken:token},{id:sender},(r) => {response=r;});return response;}};
}
{
  const h=harness(),lease=h.messages.at(-1);
  assert.equal(lease.type,"fieldOwnership"); assert.equal(lease.ownership.active,true);
  assert.deepEqual(Object.keys(lease).sort(),["ownership","type"]);
  assert.deepEqual(Object.keys(lease.ownership).sort(),["active","fieldToken"]);
  // Check serialized payload privacy, not URL trust.
  assert.doesNotMatch(JSON.stringify(lease), /example[.]com/, "hostname never leaves the worker policy boundary");
  assert.equal(h.events.input,undefined,"disabled websites observe no writing events");
  assert.equal(h.challenge(lease.ownership.fieldToken).ok,true);
  assert.equal(h.challenge(lease.ownership.fieldToken,"page-spoofer").ok,false);
  h.focused(false); assert.equal(h.challenge(lease.ownership.fieldToken).ok,false);
  h.windowEvents.blur(); assert.equal(h.messages.at(-1).ownership.active,false);
  h.focused(true);h.windowEvents.focus();assert.equal(h.messages.at(-1).ownership.active,true);
  h.document.visibilityState="hidden";h.events.visibilitychange();assert.equal(h.messages.at(-1).ownership.active,false);
  h.document.visibilityState="visible";h.events.visibilitychange();assert.equal(h.messages.at(-1).ownership.active,true);
  h.change({blockedSites:[]});assert.equal(h.messages.at(-1).ownership.active,false,"resume releases suppression immediately");
}
for (const mutation of [
  (h) => {h.field.type="password";h.field.tagName="INPUT";},
  (h) => {h.attrs.autocomplete="one-time-code";},
  (h) => {h.field.readOnly=true;},
  (h) => {h.attrs.inputmode="numeric";},
  (h) => {h.attrs["aria-label"]="Card number";},
  (h) => {h.field.closest=() => ({});}
]) {
  const h=harness();mutation(h);h.events.focusin();
  assert.equal(h.messages.at(-1).ownership.active,false,"semantic exclusions revoke ownership without reading writing");
}
for (const options of [{host:"unblocked.example"},{protocol:"chrome:"},{frame:true}]) {
  assert.equal(harness(options).messages.length,0,"unapproved hosts/surfaces send no suppression claim");
}
console.log("Disabled website content-free focus, privacy, frame, and native suppression tests passed");
