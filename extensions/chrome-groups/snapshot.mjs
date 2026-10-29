// Whitelist group metadata and IDs only: no tab titles, URLs or page content.
export function makeSnapshot({windows,tabs,groups,instanceID,sequence}) {
  const normal = new Set(windows.filter(w=>w.incognito===false && w.type==='normal').map(w=>w.id));
  const visibleGroups = groups.filter(g=>normal.has(g.windowId));
  const groupIDs = new Set(visibleGroups.map(g=>g.id));
  return {
    version:1,type:'snapshot',instanceID,sequence,windowIDs:[...normal],
    groups:visibleGroups.map(g=>({id:g.id,windowID:g.windowId,title:(g.title||'').slice(0,512),color:g.color,collapsed:!!g.collapsed})),
    tabs:tabs.filter(t=>!t.incognito && normal.has(t.windowId) && groupIDs.has(t.groupId) && Number.isInteger(t.id))
      .map(t=>({tabID:t.id,windowID:t.windowId,groupID:t.groupId}))
  };
}
