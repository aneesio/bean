const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const root = path.join(__dirname,"..");
const source = fs.readFileSync(path.join(root,"src/sitePolicy.js"),"utf8") + "\n" +
  fs.readFileSync(path.join(root,"background.js"),"utf8");
const writingFiles = ["src/sitePolicy.js","src/localDetector.js","src/trustPolicy.js",
  "src/issueMapping.js","src/overlay.js","src/contentScript.js"];
const guardFiles = ["src/sitePolicy.js","src/ownershipGuard.js"];

function harness({settings={},registrationError=false,policyReadError=false,navigateAfterProbe=false}={}) {
  let installed, startup;
  const changes=[];
  const storage={settingsSchemaVersion:6,blockedSites:[],...settings};
  const tabs=[];
  const probes=[],injections=[];
  let queryCount=0,registrationFinished=false;
  let afterProbe=null;
  const chrome={
    runtime:{id:"bean-test",lastError:null,onInstalled:{addListener:fn=>{installed=fn;}},
      onStartup:{addListener:fn=>{startup=fn;}},onMessage:{addListener(){}},openOptionsPage(){}},
    storage:{local:{
      get:(_keys,callback)=>{
        if(policyReadError && registrationFinished) chrome.runtime.lastError={message:"storage unavailable"};
        callback({...storage});chrome.runtime.lastError=null;
      },
      set:(values,callback)=>{Object.assign(storage,values);callback();},
      remove:(keys,callback)=>{for(const key of keys) delete storage[key];callback();}
    },onChanged:{addListener:fn=>changes.push(fn)}},
    tabs:{query:(filter,callback)=>{
      queryCount++;assert.deepEqual(Array.from(filter.url),["http://*/*","https://*/*"]);
      assert.equal(registrationFinished,true,"existing documents refresh only after registration finishes");
      callback(tabs.map(tab=>({id:tab.id,status:tab.status,discarded:tab.discarded})));
    }},
    scripting:{unregisterContentScripts:(_filter,callback)=>callback(),
      registerContentScripts:(_scripts,callback)=>{
        registrationFinished=true;
        if(registrationError) chrome.runtime.lastError={message:"registration failed"};
        callback();chrome.runtime.lastError=null;
      },
      executeScript:(details,callback)=>{
        const tab=tabs.find(tab=>tab.id===details.target.tabId);
        assert.ok(tab);assert.equal(details.target.allFrames,undefined);
        if(details.func) {
          probes.push(details);
          assert.deepEqual(Array.from(details.target.frameIds),[0]);
          const result=vm.runInNewContext(`(${details.func.toString()})()`,tab.world);
          if(afterProbe) afterProbe();
          callback([{frameId:0,documentId:tab.documentID,result}]);
        } else {
          assert.deepEqual(Array.from(details.target.documentIds),[tab.documentID]);
          assert.equal(details.target.frameIds,undefined,"the update is pinned to the probed document");
          injections.push(details);
          if(navigateAfterProbe) chrome.runtime.lastError={message:"No document with that id"};
          callback();chrome.runtime.lastError=null;
        }
      }
    }
  };
  const context=vm.createContext({chrome,URL,Object,Array,Set,Map,Date,Math,Number,String,
    setTimeout:()=>1,clearTimeout(){}});
  vm.runInContext(source,context);
  function addTab({id=tabs.length+1,url="https://example.com/draft",status="complete",discarded=false,
    alreadyLoaded=false,guardLoaded=false,qaMock=false,subframe=false}={}) {
    const orphan={removed:false,remove(){this.removed=true;}};
    const bridge={removed:false,remove(){this.removed=true;}};
    const editor={value:"Unsent draft",selectionStart:2,selectionEnd:5};
    const document={activeElement:editor,documentElement:{dataset:qaMock ? {beanQaMode:"mock"}:{}},
      querySelectorAll:selector=>{
        assert.equal(selector,"#bean-inline-host[data-bean-overlay][data-bean='overlay'],[data-bean-keyboard-bridge][data-bean='overlay']");
        return [orphan,bridge];
      }};
    const window={__beanInlineContentScriptLoaded:alreadyLoaded,__beanOwnershipGuardLoaded:guardLoaded};
    window.top=subframe ? {} : window;
    const tab={id,status,discarded,documentID:`doc-${id}`,orphan,bridge,editor,
      world:{window,document,location:new URL(url)}};
    tabs.push(tab);return tab;
  }
  return {addTab,probes,injections,storage,chrome,context,install:()=>installed({reason:"update"}),startup:()=>startup(),
    queryCount:()=>queryCount,setAfterProbe:fn=>{afterProbe=fn;},
    changePolicy:values=>{Object.assign(storage,values);for(const fn of changes) fn(Object.fromEntries(Object.entries(values).map(([key,value])=>[key,{newValue:value}])) ,"local");}};
}

{
  const h=harness();const tab=h.addTab();h.install();
  assert.equal(h.injections.length,1);
  assert.deepEqual(Array.from(h.injections[0].files),writingFiles);
  assert.equal(tab.orphan.removed,true);assert.equal(tab.bridge.removed,true);
  assert.equal(tab.world.document.activeElement,tab.editor);
  assert.deepEqual(tab.editor,{value:"Unsent draft",selectionStart:2,selectionEnd:5},
    "reloading Bean never reloads the tab, writes the draft, moves focus, or changes selection");
  const queries=h.queryCount();h.startup();
  assert.equal(h.queryCount(),queries,"ordinary registration refresh does not repeatedly re-inject existing pages");
}
{
  const h=harness({settings:{blockedSites:["example.com"]}});const tab=h.addTab();h.install();
  assert.deepEqual(Array.from(h.injections[0].files),guardFiles,"blocked hosts receive no writing scripts");
  assert.equal(tab.orphan.removed,true,"old presentation is retired even on blocked websites");
}
{
  const h=harness({settings:{pausedSites:{"example.com":Date.now()+60000}}});h.addTab();h.install();
  assert.deepEqual(Array.from(h.injections[0].files),writingFiles,
    "paused hosts use the normal script's tested no-writing pause and expiry handling");
}
for(const options of [{registrationError:true},{policyReadError:true},{settings:{blockedSites:["bad..host"]}}]) {
  const h=harness(options);h.addTab();h.install();
  assert.equal(h.injections.length,0,"failed registration or unreadable/corrupt policy never injects writing assistance");
  if(options.registrationError) assert.equal(h.queryCount(),0);
}
{
  const h=harness();h.addTab();h.setAfterProbe(()=>h.changePolicy({blockedSites:["example.com"]}));h.install();
  assert.deepEqual(Array.from(h.injections[0].files),guardFiles,"policy is read again after the document probe");
}
{
  const h=harness();h.addTab();h.setAfterProbe(()=>vm.runInContext("blocklistMutationRunning = true",h.context));h.install();
  assert.equal(h.injections.length,0,"an in-flight privacy mutation prevents re-injection");
}
{
  const h=harness({navigateAfterProbe:true});h.addTab();assert.doesNotThrow(()=>h.install());
  assert.equal(h.injections.length,1,"navigation errors end the pinned attempt without falling back to a newer document");
}
{
  const h=harness();
  const tabs=[h.addTab({alreadyLoaded:true}),h.addTab({guardLoaded:true}),h.addTab({status:"loading"}),
    h.addTab({discarded:true}),h.addTab({url:"chrome://extensions/"}),h.addTab({subframe:true}),
    h.addTab({url:"http://localhost/test/fixtures/editor.html",qaMock:true})];
  h.install();assert.equal(h.injections.length,0);
  assert.ok(tabs.every(tab=>!tab.orphan.removed && !tab.bridge.removed),
    "current worlds, loading/discarded tabs, restricted pages, frames, and the QA mock are left alone");
}
console.log("Browser extension in-place update, document binding, orphan cleanup, and policy tests passed");
