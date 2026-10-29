// Close only the exact saved ordinary tab, and refuse a navigated or pinned target.
(function () {
    try {
        var ids=TARGET_IDENTIFIERS,chrome=Application('com.google.Chrome');
        if (!chrome.running()) return JSON.stringify({status:'notRunning'});
        var windows=chrome.windows(),target=null;
        for (var i=0;i<windows.length;i++) if (String(windows[i].id())===ids.windowID) {target=windows[i];break;}
        if (!target || String(target.mode())!=='normal') return JSON.stringify({status:'changed'});
        var tabs=target.tabs();
        for (var j=0;j<tabs.length;j++) if (String(tabs[j].id())===ids.tabID) {
            var values=tabs[j].properties();
            if (String(values.url || values.URL || '')!==ids.url || values.pinned===true) return JSON.stringify({status:'changed'});
            tabs[j].close();
            // beforeunload can cancel a close. Do not report success until the ID is absent.
            delay(0.1);
            var after=chrome.windows();
            for(var a=0;a<after.length;a++) if(String(after[a].id())===ids.windowID) {
                if(String(after[a].mode())!=='normal') return JSON.stringify({status:'changed'});
                var remaining=after[a].tabs();
                for(var b=0;b<remaining.length;b++) if(String(remaining[b].id())===ids.tabID) return JSON.stringify({status:'changed'});
            }
            return JSON.stringify({status:'removed'});
        }
        return JSON.stringify({status:'changed'});
    } catch(e) { return JSON.stringify({status:'error',errorCode:Number(e.errorNumber || e.number || 0)}); }
})();
