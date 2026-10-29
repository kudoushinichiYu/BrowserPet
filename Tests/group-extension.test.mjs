import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
import {makeSnapshot} from '../extensions/chrome-groups/snapshot.mjs';
let passed=0;
function check(name,fn) { fn(); passed++;console.log('PASS '+name); }
const data={instanceID:'00000000-0000-0000-0000-000000000001',sequence:1,
  windows:[{id:1,type:'normal',incognito:false},{id:2,type:'normal',incognito:true},{id:3,type:'popup',incognito:false}],
  groups:[{id:10,windowId:1,title:'原有分组',color:'green',collapsed:true},{id:20,windowId:2,title:'PRIVATE',color:'red',collapsed:false}],
  tabs:[{id:100,windowId:1,groupId:10,incognito:false,title:'secret-title',url:'https://secret.example'},{id:200,windowId:2,groupId:20,incognito:true},{id:101,windowId:1,groupId:-1,incognito:false}]};
check('original title/color/collapse retained',()=>{const r=makeSnapshot(data);assert.equal(r.groups[0].title,'原有分组');assert.equal(r.groups[0].collapsed,true);assert.equal(r.groups[0].color,'green');});
check('private and popup windows excluded',()=>{const r=makeSnapshot(data);assert.deepEqual(r.windowIDs,[1]);assert.equal(r.groups.length,1);assert.equal(r.tabs.length,1);assert.ok(!JSON.stringify(r).includes('PRIVATE'));});
check('only membership IDs cross the bridge',()=>{const r=makeSnapshot(data);assert.deepEqual(Object.keys(r.tabs[0]).sort(),['groupID','tabID','windowID']);assert.ok(!JSON.stringify(r).includes('secret'));});
check('ungrouped tabs stay out of original-group map',()=>assert.equal(makeSnapshot(data).tabs.some(t=>t.tabID===101),false));
check('clearing all groups still reports profile windows',()=>{const r=makeSnapshot({...data,groups:[]});assert.deepEqual(r.windowIDs,[1]);assert.deepEqual(r.tabs,[]);});
const manifest=JSON.parse(fs.readFileSync('extensions/chrome-groups/manifest.json','utf8'));
check('no page host/title/url access permission',()=>{assert.deepEqual(manifest.permissions,['tabGroups','nativeMessaging']);assert.equal(manifest.incognito,'not_allowed');assert.equal(manifest.host_permissions,undefined);assert.equal(manifest.content_scripts,undefined);});
check('native origin pinned to deterministic extension ID',()=>{const hex=crypto.createHash('sha256').update(Buffer.from(manifest.key,'base64')).digest('hex').slice(0,32);const id=[...hex].map(c=>String.fromCharCode(97+parseInt(c,16))).join('');const config=JSON.parse(fs.readFileSync('Resources/group-bridge-config.json','utf8'));assert.equal(id,config.extensionID);assert.equal(config.extensionOrigin,`chrome-extension://${id}/`);});
console.log(`${passed} group extension checks passed. No browser extension was installed.`);
