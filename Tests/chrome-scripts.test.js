const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const scan = fs.readFileSync('Resources/chrome-scan.js','utf8');
const activate = fs.readFileSync('Resources/chrome-activate.js','utf8');
let passed = 0;
function test(name, fn) { fn(); passed++; console.log('PASS '+name); }
function makeWindow(id, mode, records) {
  const state = {active:1,minimized:true,front:false,metadataReads:0};
  const tabs = () => { state.metadataReads++; return records.map(t=>({id:()=>t.id,title:()=>t.title,url:()=>t.url,properties:()=>t})); };
  tabs.properties = () => { state.metadataReads++; return records; };
  const w={id:()=>id,mode:()=>mode,name:()=>`窗口 ${id}`,tabs,state};
  Object.defineProperties(w,{
    activeTabIndex:{get:()=>()=>state.active,set:v=>state.active=v},
    activeTab:{get:()=>({id:()=>records[state.active-1].id})},
    minimized:{get:()=>()=>state.minimized,set:v=>state.minimized=v},
    index:{set:v=>state.front=v===1}
  });
  return w;
}
function run(script, windows, running=true) {
  const chrome={running:()=>running,windows:()=>windows,activate:()=>{}};
  return JSON.parse(vm.runInNewContext(script,{Application:()=>chrome,delay:()=>{}}));
}
test('multiple windows and profiles remain independent',()=>{
  const windows=[makeWindow('1','normal',[{id:'11',title:'同名',url:'https://a.test'}]),makeWindow('2','normal',[{id:'22',title:'同名',url:'https://a.test'}])];
  const r=run(scan,windows);assert.equal(r.tabs.length,2);assert.equal(r.normalWindowCount,2);assert.notEqual(r.tabs[0].windowID,r.tabs[1].windowID);
});
test('incognito excluded before any tab metadata read',()=>{
  const hidden=makeWindow('2','incognito',[{id:'99',title:'PRIVATE',url:'https://secret.test'}]);
  const r=run(scan,[makeWindow('1','normal',[]),hidden]);
  assert.equal(hidden.state.metadataReads,0);assert.equal(r.excludedPrivateWindowCount,1);assert.equal(r.tabs.length,0);
});
test('permission denial is not swallowed as an empty successful snapshot',()=>{
  const w=makeWindow('1','normal',[]);w.mode=()=>{throw {errorNumber:-1743}};
  const r=run(scan,[w]);assert.equal(r.status,'error');assert.equal(r.errorCode,-1743);
});
test('disappearing window produces explicit partial-snapshot count',()=>{
  const w=makeWindow('1','normal',[]);w.mode=()=>{throw {errorNumber:-1728}};
  const r=run(scan,[w]);assert.equal(r.status,'ok');assert.equal(r.skippedWindowCount,1);
});
test('browser not running is distinct from zero tabs',()=>assert.equal(run(scan,[],false).status,'notRunning'));
test('quotes, tabs, emoji, and newlines survive JSON',()=>{
  const title='行一\n"引号"\t🐈';assert.equal(run(scan,[makeWindow('1','normal',[{id:'11',title,url:'https://a.test'}])]).tabs[0].title,title);
});
test('activation locates exact original ids and restores minimized window',()=>{
  const one=makeWindow('1','normal',[{id:'11'}]),two=makeWindow('2','normal',[{id:'21'},{id:'22'}]);
  const script=activate.replace('TARGET_IDENTIFIERS',JSON.stringify({windowID:'2',tabID:'22'}));
  const r=run(script,[one,two]);assert.equal(r.status,'selected');assert.equal(two.state.active,2);assert.equal(two.state.minimized,false);assert.equal(two.state.front,true);assert.equal(one.state.minimized,true);
});
test('closed target does not open a replacement URL or select a same-name tab',()=>{
  const w=makeWindow('1','normal',[{id:'11'}]);
  const r=run(activate.replace('TARGET_IDENTIFIERS',JSON.stringify({windowID:'1',tabID:'gone'})),[w]);
  assert.equal(r.status,'closed');assert.equal(w.state.minimized,true);
});
test('activation refuses a private window',()=>{
  const w=makeWindow('1','incognito',[{id:'11'}]);
  assert.equal(run(activate.replace('TARGET_IDENTIFIERS',JSON.stringify({windowID:'1',tabID:'11'})),[w]).status,'closed');
});
console.log(`${passed} script contract tests passed. These mocks do not replace real Chrome UI acceptance.`);
