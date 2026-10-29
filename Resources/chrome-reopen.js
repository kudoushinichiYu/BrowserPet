// Restoration is an explicit new navigation, never used by ordinary tab activation.
(function () {
    try {
        var ids=TARGET_IDENTIFIERS,chrome=Application('com.google.Chrome');
        if (!/^https?:\/\//i.test(ids.url)) return JSON.stringify({status:'invalid'});
        if (!chrome.running()) return JSON.stringify({status:'notRunning'});
        var windows=chrome.windows(),target=null,created=false;
        for(var i=0;i<windows.length;i++) if(String(windows[i].id())===ids.windowID && String(windows[i].mode())==='normal') {target=windows[i];break;}
        if (!target) {target=chrome.Window({mode:'normal'});chrome.windows.push(target);created=true;}
        if(String(target.mode())!=='normal') return JSON.stringify({status:'invalid'});
        var initial=created?target.tabs():[],page;
        if(initial.length===1) {page=initial[0];page.url=ids.url;}
        else {page=chrome.Tab({url:ids.url});target.tabs.push(page);}
        var windowID=String(target.id()),tabID=String(page.id());
        // A constructor's local proxy is not evidence that Chrome kept the page.
        // Re-read the live ordinary window and URL before acknowledging restoration.
        for(var attempt=0;attempt<4;attempt++) {
            delay(0.2);
            var live=chrome.windows();
            for(var w=0;w<live.length;w++) if(String(live[w].id())===windowID && String(live[w].mode())==='normal') {
                var actual=live[w].tabs();
                for(var t=0;t<actual.length;t++) if(String(actual[t].id())===tabID) {
                    var properties=actual[t].properties();
                    if(String(properties.url || properties.URL || '')===ids.url) return JSON.stringify({status:'opened',verified:true,windowID:windowID,tabID:tabID});
                }
            }
        }
        return JSON.stringify({status:'unverified'});
    } catch(e) {return JSON.stringify({status:'error',errorCode:Number(e.errorNumber || e.number || 0)});}
})();
