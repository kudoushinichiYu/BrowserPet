// JXA: title/URL metadata only. Never inspect tabs before checking window mode.
(function () {
    function code(e) { return Number(e.errorNumber || e.number || 0); }
    function missing(e) { return [-1728, -1719].indexOf(code(e)) >= 0; }
    try {
        var chrome = Application('com.google.Chrome');
        var result = {status:'ok', tabs:[], currentWindowID:null, normalWindowCount:0,
            excludedPrivateWindowCount:0, skippedWindowCount:0, errorCode:null};
        if (!chrome.running()) { result.status='notRunning'; return JSON.stringify(result); }
        var windows = chrome.windows();
        for (var i=0; i<windows.length; i++) {
            var w=windows[i];
            try {
                var mode=String(w.mode());
                if (mode==='incognito') { result.excludedPrivateWindowCount++; continue; }
                if (mode!=='normal') { result.skippedWindowCount++; continue; }
                var windowID=String(w.id()), name='', active=0;
                try { name=String(w.name() || ''); } catch(e) { if (!missing(e)) throw e; }
                try { active=Number(w.activeTabIndex()); } catch(e) { if (!missing(e)) throw e; }
                result.normalWindowCount++;
                if (i===0) result.currentWindowID=windowID;
                var tabs=w.tabs();
                for (var j=0; j<tabs.length; j++) {
                    try {
                        var t=tabs[j];
                        var metadata=null;
                        try { metadata=t.properties(); } catch(e) { if (!missing(e)) throw e; }
                        if (!metadata || metadata.id===undefined || metadata.title===undefined || (metadata.url===undefined && metadata.URL===undefined)) {
                            metadata={id:t.id(),title:t.title(),url:t.url()};
                        }
                        result.tabs.push({browser:'chrome',windowID:windowID,tabID:String(metadata.id),
                            title:String(metadata.title || ''),url:String(metadata.url || metadata.URL || ''),windowTitle:name,
                            windowNumber:i+1,isActive:i===0 && j+1===active});
                    } catch(e) { if (!missing(e)) throw e; result.skippedWindowCount++; }
                }
            } catch(e) {
                if (!missing(e)) throw e;
                result.skippedWindowCount++;
            }
        }
        return JSON.stringify(result);
    } catch(e) {
        return JSON.stringify({status:'error',tabs:[],currentWindowID:null,normalWindowCount:0,
            excludedPrivateWindowCount:0,skippedWindowCount:0,errorCode:code(e)});
    }
})();
