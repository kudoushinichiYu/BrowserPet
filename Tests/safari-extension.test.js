const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const {snapshot,activate}=require('../extensions/safari-tabs/protocol.js');
let passed=0;
async function check(name,fn){await fn();passed++;console.log('PASS '+name);}
(async()=>{
  const identity={instanceID:'00000000-0000-0000-0000-000000000001',profileID:'00000000-0000-0000-0000-000000000002'};
  await check('Safari private and popup windows excluded before title/URL reads',async()=>{
    const queried=[];
    const privateTab={id:99,windowId:1,incognito:true,get title(){throw Error('Private title read');},get url(){throw Error('Private URL read');}};
    const api={windows:{getAll:async()=>[{id:1,incognito:false,type:'normal',focused:true},{id:2,incognito:true,type:'normal'},{id:3,incognito:false,type:'popup'}]},
      tabs:{query:async q=>{queried.push(q.windowId);assert.equal(q.windowId,1);return [{id:10,windowId:1,incognito:false,title:'Same title',url:'https://example.com',active:true},privateTab];}}};
    const r=await snapshot(api,identity,1,null);assert.deepEqual(queried,[1]);assert.equal(r.tabs.length,1);assert.equal(r.tabs[0].id,10);assert.equal(r.profileID,identity.profileID);
  });
  function fixture(mode='normal'){
    const state={active:11,focused:false,minimized:true,updates:0,queries:0};
    const window=()=>({id:1,type:'normal',incognito:mode!=='normal',focused:state.focused,state:state.minimized?'minimized':'normal'});
    const api={windows:{get:async()=>window(),update:async(id,v)=>{assert.equal(id,1);state.focused=v.focused;if(v.state==='normal')state.minimized=false;}},
      tabs:{query:async q=>{state.queries++;return [11,12].filter(id=>!q.active||state.active===id).map(id=>({id,windowId:1,incognito:false,title:'Same title',url:'https://example.com'}));},
        update:async(id,v)=>{state.updates++;assert.equal(v.active,true);state.active=id;}}};return {api,state};
  }
  await check('Safari tab privacy flag may be omitted only inside a positively ordinary parent window',async()=>{
    const queried=[];
    const api={windows:{getAll:async()=>[{id:1,type:'normal',incognito:false},{id:2,type:'normal'}]},
      tabs:{query:async q=>{queried.push(q.windowId);return [{id:10,windowId:1,title:'Public',url:'https://example.com',active:true}];}}};
    const r=await snapshot(api,identity,1,null);assert.deepEqual(queried,[1]);assert.equal(r.tabs.length,1);assert.equal(r.diagnostics.unknownTabPrivacy,1);
    const f=fixture();const query=f.api.tabs.query;f.api.tabs.query=async q=>(await query(q)).map(t=>{delete t.incognito;return t;});
    assert.equal((await activate(f.api,{id:'test',instanceID:identity.instanceID,windowID:1,tabID:12},identity.instanceID)).status,'selected');
  });
  const command={id:'00000000-0000-0000-0000-000000000003',instanceID:identity.instanceID,windowID:1,tabID:12};
  await check('Safari switches exact original ID among duplicate titles and restores minimized window',async()=>{
    const f=fixture();const r=await activate(f.api,command,identity.instanceID);assert.equal(r.status,'selected');assert.equal(f.state.active,12);assert.equal(f.state.minimized,false);assert.equal(f.state.focused,true);
  });
  await check('Safari closed IDs do not select another page or open a replacement URL',async()=>{
    const f=fixture();assert.equal((await activate(f.api,{...command,tabID:999},identity.instanceID)).status,'closed');assert.equal(f.state.updates,0);
  });
  await check('Safari private activation refused before querying tabs',async()=>{
    const f=fixture('private');assert.equal((await activate(f.api,command,identity.instanceID)).status,'closed');assert.equal(f.state.queries,0);
  });
  await check('Safari restarted worker rejects old instance commands',async()=>{
    const f=fixture();assert.equal((await activate(f.api,command,'replacement')).status,'closed');assert.equal(f.state.queries,0);
  });
  await check('Safari helper has no page injection, history or bookmark API permission',()=>{
    const manifest=JSON.parse(fs.readFileSync('extensions/safari-tabs/manifest.json'));assert.equal(manifest.content_scripts,undefined);assert.equal(manifest.incognito,'not_allowed');assert.ok(!manifest.permissions.includes('history'));assert.ok(!manifest.permissions.includes('bookmarks'));
    const background=fs.readFileSync('extensions/safari-tabs/background.js','utf8');assert.ok(!/executeScript|scripting\.|innerHTML/.test(background));assert.equal((background.match(/fetch\(/g)||[]).length,1);
  });
  await check('Edge automation uses the Edge bundle and retains private-window protections',()=>{
    for(const name of ['scan','activate']){
      const original=fs.readFileSync(`Resources/chrome-${name}.js`,'utf8');const edge=original.replaceAll('com.google.Chrome','com.microsoft.edgemac');const ids={windowID:'7',tabID:'8'};
      let queried=0,selected=1;const tab={id:()=>8,properties:()=>({id:8,title:'Edge page',url:'https://example.com'})};
      const window={id:()=>7,mode:()=> 'normal',name:()=>'',tabs:()=>{queried++;return [tab];}};
      Object.defineProperties(window,{activeTabIndex:{get:()=>()=>selected,set:n=>selected=n},activeTab:{get:()=>tab},minimized:{get:()=>()=>false,set:()=>{}},index:{set:()=>{}}});
      const result=JSON.parse(vm.runInNewContext(edge.replace('TARGET_IDENTIFIERS',JSON.stringify(ids)),{Application:id=>{assert.equal(id,'com.microsoft.edgemac');return {running:()=>true,windows:()=>[window],activate:()=>{}};},delay:()=>{}}));
      assert.equal(result.status,name==='scan'?'ok':'selected');assert.ok(queried>0);
      window.mode=()=> 'incognito';queried=0;const hidden=JSON.parse(vm.runInNewContext(edge.replace('TARGET_IDENTIFIERS',JSON.stringify(ids)),{Application:()=>({running:()=>true,windows:()=>[window]}),delay:()=>{}}));
      assert.equal(queried,0);assert.equal(name==='scan'?hidden.tabs.length:hidden.status,name==='scan'?0:'closed');
    }
  });
  console.log(`${passed} Safari/Edge extension and scripting checks passed; no real browser data used.`);
})().catch(error=>{console.error(error);process.exitCode=1;});
