const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const {perform,snapshot}=require('../extensions/safari-tabs/protocol.js');
let count=0;
async function check(name,fn){await fn();count++;console.log('PASS '+name);}
function chromeFixture({mode='normal',url='https://example.test/a',pinned=false,cancel=false}={}) {
  const state={closed:0,reads:0,created:0,pages:[]};
  const page={id:()=>2,properties:()=>({url,pinned}),close:()=>{state.closed++;if(!cancel)state.pages=[];}};
  state.pages=[page];
  const window={id:()=>1,mode:()=>mode,tabs:()=>{state.reads++;return state.pages;}};
  const windows=()=>[window];
  const app={running:()=>true,windows};
  return {state,app,window};
}
function run(name,app,ids){return JSON.parse(vm.runInNewContext(fs.readFileSync(`Resources/chrome-${name}.js`,'utf8').replace('TARGET_IDENTIFIERS',JSON.stringify(ids)),{Application:()=>app,delay:()=>{}}));}
(async()=>{
 const ids={windowID:'1',tabID:'2',url:'https://example.test/a'};
 await check('Chrome close uses exact ID and saved URL then verifies disappearance',()=>{
   const f=chromeFixture();assert.equal(run('close',f.app,ids).status,'removed');assert.equal(f.state.closed,1);
 });
 await check('Chrome close refuses changed URL and pinned targets',()=>{
   for(const options of [{url:'https://changed.test/'},{pinned:true}]) {const f=chromeFixture(options);assert.equal(run('close',f.app,ids).status,'changed');assert.equal(f.state.closed,0);}
 });
 await check('Chrome private windows are rejected before tab metadata is queried',()=>{
   const f=chromeFixture({mode:'incognito'});assert.equal(run('close',f.app,ids).status,'changed');assert.equal(f.state.reads,0);
 });
 await check('Chrome cancelled close is reported as unconfirmed rather than deleted',()=>{
   const f=chromeFixture({cancel:true});assert.equal(run('close',f.app,ids).status,'changed');
 });
 await check('Chrome restore creates an explicitly ordinary window and retains returned IDs',()=>{
   let created=0,uri='';const page={id:()=>91,properties:()=>({url:uri})};Object.defineProperty(page,'url',{set:value=>uri=value});
   const target={id:()=>90,mode:()=> 'normal',tabs:()=>[page]};
   const live=[];const windows=()=>live;windows.push=w=>{assert.equal(w,target);live.push(w);};
   const app={running:()=>true,windows,Window:values=>{assert.equal(values.mode,'normal');created++;return target;}};
   assert.deepEqual(run('reopen',app,{...ids,windowID:'gone'}),{status:'opened',verified:true,windowID:'90',tabID:'91'});assert.equal(created,1);assert.equal(uri,ids.url);
 });
 await check('Chrome cannot acknowledge a constructor proxy absent from live windows',()=>{
   const page={id:()=>91,properties:()=>({url:ids.url})};Object.defineProperty(page,'url',{set:()=>{}});
   const target={id:()=>90,mode:()=> 'normal',tabs:()=>[page]},windows=()=>[];windows.push=()=>{};
   const app={running:()=>true,windows,Window:()=>target};assert.equal(run('reopen',app,{...ids,windowID:'gone'}).status,'unverified');
 });
 await check('Chrome cannot acknowledge a new tab whose live URL differs',()=>{
   const page={id:()=>91,properties:()=>({url:'chrome://newtab/'})};Object.defineProperty(page,'url',{set:()=>{}});
   const target={id:()=>90,mode:()=> 'normal',tabs:()=>[page]},live=[],windows=()=>live;windows.push=w=>live.push(w);
   const app={running:()=>true,windows,Window:()=>target};assert.equal(run('reopen',app,{...ids,windowID:'gone'}).status,'unverified');
 });
 await check('Chrome restore never navigates a scripting or file URL',()=>{
   const f=chromeFixture();for(const url of ['javascript:alert(1)','data:text/html,x','file:///private/test']) assert.equal(run('reopen',f.app,{...ids,url}).status,'invalid');
 });
 function safariFixture({privateWindow=false,pinned=false,url=ids.url,cancel=false}={}) {
   const state={queries:0,removed:0,created:0,pages:[{id:2,windowId:1,url,pinned,incognito:false}]};
   const window={id:1,incognito:privateWindow,type:'normal'};
   const api={windows:{get:async()=>window,getAll:async()=>[window],create:async values=>{assert.equal(values.incognito,false);assert.equal(values.type,'normal');state.created++;return {id:9,incognito:false,type:'normal',tabs:[{id:10,windowId:9,incognito:false}]};}},
    tabs:{query:async()=>{state.queries++;return state.pages;},remove:async id=>{assert.equal(id,2);state.removed++;if(!cancel)state.pages=[];},create:async values=>({id:11,windowId:values.windowId,incognito:false})}};
   return {state,api};
 }
 const command={id:'command',instanceID:'worker',action:'close',windowID:1,tabID:2,url:ids.url};
 await check('Safari refuses private closure before tab reads',async()=>{
   const f=safariFixture({privateWindow:true});assert.equal((await perform(f.api,command,'worker')).status,'closed');assert.equal(f.state.queries,0);assert.equal(f.state.removed,0);
 });
 await check('Safari close refuses navigated or pinned pages and verifies cancellation',async()=>{
   for(const options of [{url:'https://changed.test/'},{pinned:true},{cancel:true}]) {const f=safariFixture(options);assert.equal((await perform(f.api,command,'worker')).status,'changed');if(!options.cancel)assert.equal(f.state.removed,0);}
 });
 await check('Safari confirmed closure and ordinary-window recreation return explicit acknowledgements',async()=>{
   const f=safariFixture();assert.equal((await perform(f.api,command,'worker')).status,'removed');
   const reply=await perform(f.api,{...command,action:'reopen',windowID:0},'worker');assert.equal(reply.status,'opened');assert.equal(reply.windowID,9);assert.equal(reply.tabID,10);assert.equal(f.state.created,1);
 });
 await check('Safari old-worker, unknown command and scripting URLs cannot trigger navigation',async()=>{
   const f=safariFixture();for(const value of [{...command,instanceID:'retired'},{...command,action:'unknown'},{...command,action:'reopen',url:'javascript:alert(1)'}]) assert.notEqual((await perform(f.api,value,'worker')).status,'opened');assert.equal(f.state.created,0);assert.equal(f.state.removed,0);
 });
 await check('Safari snapshot advertises workspace support for safe capability negotiation',async()=>{
   const f=safariFixture();const result=await snapshot(f.api,{instanceID:'worker',profileID:'profile'},1,null);assert.ok(result.capabilities.includes('workspaces-v1'));
 });
 console.log(`${count} workspace browser-operation checks passed. No real tabs were closed or opened.`);
})().catch(error=>{console.error(error);process.exitCode=1;});
