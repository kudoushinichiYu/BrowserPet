// Identifiers are supplied as one JSON object by the adapter.
(function () {
    try {
        var identifiers=TARGET_IDENTIFIERS;
        var chrome=Application('com.google.Chrome');
        if (!chrome.running()) return JSON.stringify({status:'notRunning'});
        var windows=chrome.windows(), target=null;
        for (var i=0;i<windows.length;i++) {
            if (String(windows[i].id())===identifiers.windowID) { target=windows[i]; break; }
        }
        if (target===null || String(target.mode())!=='normal') return JSON.stringify({status:'closed'});
        var tabs=target.tabs(), index=-1;
        for (var j=0;j<tabs.length;j++) {
            if (String(tabs[j].id())===identifiers.tabID) { index=j+1; break; }
        }
        if (index<0) return JSON.stringify({status:'closed'});
        target.activeTabIndex=index;
        target.minimized=false;
        target.index=1;
        chrome.activate();
        delay(0.15);
        var verified=String(target.activeTab.id())===identifiers.tabID && !target.minimized();
        return JSON.stringify({status:verified?'selected':'unverified',selected:verified});
    } catch(e) {
        var n=Number(e.errorNumber || e.number || 0);
        return JSON.stringify({status:[-1728,-1719].indexOf(n)>=0?'closed':'error',errorCode:n});
    }
})();
