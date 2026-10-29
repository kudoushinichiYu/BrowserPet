/* Only the loopback endpoint below is contacted. No content script or page JavaScript. */
const api = browser;
const instanceID = crypto.randomUUID();
let profileID,sequence=0,busy=false,reply=null;
const completed = new Map();
async function status(ok,diagnostics) {
  await api.browserAction.setBadgeText({text:ok?'':'!'});
  const counts=diagnostics ? ` (${diagnostics.windows}/${diagnostics.totalWindows} windows, ${diagnostics.indexed}/${diagnostics.candidates} tabs, ${diagnostics.unknownTabPrivacy} legacy flags)` : '';
  await api.browserAction.setTitle({title:ok?'BrowserPet: Safari connected'+counts:'BrowserPet: run desktop pet and check website access'});
}
async function sync() {
  if (busy || !profileID) return;
  busy=true;
  const controller = new AbortController(),timeout=setTimeout(()=>controller.abort(),2500);
  try {
    const snapshot = await BrowserPetSafari.snapshot(api,{instanceID,profileID},++sequence,reply);
    const response = await fetch(BROWSERPET_PAIRING.endpoint,{method:'POST',headers:{
      'Content-Type':'application/json','Authorization':'Bearer '+BROWSERPET_PAIRING.token},
      body:JSON.stringify(snapshot),signal:controller.signal,cache:'no-store',credentials:'omit'});
    if (!response.ok) throw new Error('Local bridge unavailable');
    const data = await response.json();
    if (data.connected !== true) throw new Error('Local bridge unavailable');
    reply=null;
    if (data.command) {
      const command=data.command;
      reply=completed.get(command.id) || await BrowserPetSafari.perform(api,command,instanceID);
      completed.set(command.id,reply);
      if (completed.size>32) completed.delete(completed.keys().next().value);
    }
    await status(true,snapshot.diagnostics);
  } catch { await status(false); }
  finally {clearTimeout(timeout);busy=false;}
}
api.browserAction.onClicked.addListener(sync);
(async()=>{
  const value=await api.storage.local.get('browserpetProfileID');
  profileID=value.browserpetProfileID || crypto.randomUUID();
  await api.storage.local.set({browserpetProfileID:profileID});
  await sync();setInterval(sync,1000);
})();
