import {makeSnapshot} from './snapshot.mjs';

const instanceID = crypto.randomUUID();
let sequence=0,port=null,retryTimer=null,syncTimer=null,busy=false,queued=false;
function status(connected) {
  chrome.action.setBadgeText({text:connected?'':'!'});
  chrome.action.setBadgeBackgroundColor({color:'#C87925'});
  chrome.action.setTitle({title:connected?'BrowserPet：原分组已连接':'BrowserPet：点击重试本机分组连接'});
}
function connect() {
  if(port) return;
  try {
    const next=chrome.runtime.connectNative('local.browserpet.groups'); port=next;
    next.onMessage.addListener(reply=>status(reply.connected===true));
    next.onDisconnect.addListener(()=>{
      void chrome.runtime.lastError;
      if(port===next) port=null;
      status(false); clearTimeout(retryTimer); retryTimer=setTimeout(()=>{connect();schedule();},5000);
    });
  } catch { port=null; status(false); }
}
function schedule() { clearTimeout(syncTimer); syncTimer=setTimeout(sync,150); }
async function sync() {
  if(busy) { queued=true; return; }
  busy=true;
  try {
    const [windows,tabs,groups]=await Promise.all([chrome.windows.getAll(),chrome.tabs.query({}),chrome.tabGroups.query({})]);
    const snapshot=makeSnapshot({windows,tabs,groups,instanceID,sequence:++sequence});
    connect(); if(port) port.postMessage(snapshot);
  } catch { status(false); }
  finally { busy=false; if(queued) { queued=false;schedule(); } }
}
for(const event of [chrome.tabGroups.onCreated,chrome.tabGroups.onUpdated,chrome.tabGroups.onRemoved,chrome.tabGroups.onMoved,
  chrome.tabs.onCreated,chrome.tabs.onRemoved,chrome.tabs.onUpdated,chrome.tabs.onMoved,chrome.tabs.onAttached,chrome.tabs.onDetached,
  chrome.windows.onCreated,chrome.windows.onRemoved]) event.addListener(schedule);
chrome.action.onClicked.addListener(()=>{connect();schedule();});
chrome.runtime.onStartup.addListener(()=>{connect();schedule();});
chrome.runtime.onInstalled.addListener(()=>{connect();schedule();});
// connectNative keeps the service worker alive (Chrome 105+). No network traffic.
setInterval(schedule,15000);
connect();schedule();
