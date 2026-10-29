(function (root) {
  async function snapshot(api, identity, sequence, reply) {
    const all = await api.windows.getAll({populate:false});
    const windows = all.filter(w => w.incognito === false && w.type === 'normal');
    const tabs = [];
    let candidates=0,unknownTabPrivacy=0;
    // Query only verified ordinary windows, before accessing any title/URL properties.
    for (const window of windows) {
      const values = await api.tabs.query({windowId:window.id});
      candidates+=values.length;
      for (const tab of values) {
        if (tab.incognito === undefined) unknownTabPrivacy++;
        // The parent window was positively classified as ordinary before this query.
        // Some Safari tab objects omit the redundant incognito property.
        if (tab.incognito === true || tab.windowId !== window.id) continue;
        tabs.push({id:tab.id, windowID:window.id, title:tab.title || '', url:tab.url || '', active:!!tab.active});
      }
    }
    return {version:1, instanceID:identity.instanceID, profileID:identity.profileID, sequence,
      windows:windows.map(w => ({id:w.id, focused:!!w.focused})), tabs, reply:reply || null,
      diagnostics:{windows:windows.length,totalWindows:all.length,candidates,indexed:tabs.length,unknownTabPrivacy}};
  }
  async function activate(api, command, instanceID) {
    const result = {id:command.id,status:'error'};
    if (command.instanceID !== instanceID) return {...result,status:'closed'};
    try {
      const window = await api.windows.get(command.windowID);
      if (window.incognito !== false || window.type !== 'normal') return {...result,status:'closed'};
      const tabs = await api.tabs.query({windowId:window.id});
      if (!tabs.some(t => t.id === command.tabID && t.windowId === window.id && t.incognito !== true)) return {...result,status:'closed'};
      await api.tabs.update(command.tabID,{active:true});
      await api.windows.update(window.id,window.state === 'minimized' ? {focused:true,state:'normal'} : {focused:true});
      const selected = await api.tabs.query({windowId:window.id,active:true});
      const focused = await api.windows.get(window.id);
      return {...result,status:selected.some(t => t.id === command.tabID && t.windowId === window.id && t.incognito !== true) && focused.focused && focused.incognito === false ? 'selected':'error'};
    } catch { return {...result,status:'closed'}; }
  }
  root.BrowserPetSafari = {snapshot,activate};
  if (typeof module !== 'undefined') module.exports = root.BrowserPetSafari;
})(globalThis);
