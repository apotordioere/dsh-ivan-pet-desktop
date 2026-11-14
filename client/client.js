/**
 * dsh-ivan-pet-desktop 客户端半身：只做界面背景，不注册 slot
 * 
 * 功能：
 * 1. 向 document.head 插入 <style id="ivan-pet-bg">，设置会话主内容区背景图
 * 2. 定时（30秒）轮询 GET /ivan-pet/ui-theme 拿当前主题名
 * 3. 主题变了就换背景图（URL: GET /ivan-pet/theme/<name>.jpg）
 * 
 * 不改布局、不注册 slot、不碰输入框
 */

window.__ModuleLoader__.load({
  id: 'dsh-ivan-pet-desktop',
  factory: (require) => {
    const module = { exports: {} };
    
    module.exports.name = 'dsh-ivan-pet-desktop';
    module.exports.inject = [];
    
    module.exports.apply = function(ctx) {
      let currentTheme = null;
      let pollTimer = null;
      
      const log = (msg) => {
        try {
          console.log('[ivan-pet-desktop/client]', msg);
        } catch {}
      };
      
      // 更新背景样式
      const updateBackground = (themeName) => {
        let styleEl = document.getElementById('ivan-pet-bg');
        if (!styleEl) {
          styleEl = document.createElement('style');
          styleEl.id = 'ivan-pet-bg';
          document.head.appendChild(styleEl);
        }
        
        if (!themeName) {
          // 清除背景
          styleEl.textContent = '';
          return;
        }
        
        const imageUrl = `/ivan-pet/theme/${themeName}.jpg`;
        
        // 策略：给会话主内容区（.conversation、.main-view、.main-content 等）贴背景
        // 用 background-attachment: fixed 让背景随滚动视差移动
        // 保留原有的 background-color 作为兜底
        const css = `
/* Ivan 桌宠 - 界面背景主题：${themeName} */

/* 方案 1：会话主区域 */
.conversation,
.main-view,
.main-content,
[class*="conversation"],
[class*="session-view"],
[class*="chat-container"] {
  background-image: url("${imageUrl}") !important;
  background-size: cover !important;
  background-position: center !important;
  background-repeat: no-repeat !important;
  background-attachment: fixed !important;
}

/* 方案 2：如果上面找不到，给 body 和根容器贴 */
body {
  background-image: url("${imageUrl}") !important;
  background-size: cover !important;
  background-position: center !important;
  background-repeat: no-repeat !important;
  background-attachment: fixed !important;
}

/* 让一些遮挡层透明，让背景透出来 */
.root,
.app,
.shell,
[class*="app-root"],
[class*="main-wrapper"],
[class*="content-wrapper"] {
  background-color: transparent !important;
}

/* 消息气泡和卡片保持自己的背景，不要透明化 */
[class*="message"],
[class*="card"],
[class*="bubble"],
[class*="panel"],
[class*="dialog"],
[class*="modal"],
[class*="dropdown"],
[class*="menu"],
[class*="tooltip"],
[class*="popover"] {
  /* 保留原有背景 */
}
`;
        
        styleEl.textContent = css;
        log(`背景已设置为：${themeName}`);
      };
      
      // 轮询主题
      const pollTheme = async () => {
        try {
          const resp = await fetch('/ivan-pet/ui-theme', {
            method: 'GET',
            headers: { 'cache-control': 'no-store' }
          });
          
          if (!resp.ok) {
            log(`主题接口返回 ${resp.status}`);
            return;
          }
          
          const data = await resp.json();
          const themeName = data?.name || null;
          
          if (themeName !== currentTheme) {
            currentTheme = themeName;
            updateBackground(themeName);
          }
        } catch (err) {
          // 接口不通就静默（宿主可能还没启动）
        }
      };
      
      // 启动
      const start = () => {
        log('客户端半身已加载');
        
        // 立即查一次
        pollTheme();
        
        // 每 30 秒轮询
        pollTimer = setInterval(pollTheme, 30000);
      };
      
      // 清理
      const dispose = () => {
        if (pollTimer) {
          clearInterval(pollTimer);
          pollTimer = null;
        }
        
        const styleEl = document.getElementById('ivan-pet-bg');
        if (styleEl) {
          styleEl.remove();
        }
        
        log('客户端半身已卸载');
      };
      
      // 等 DOM ready
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', start);
      } else {
        start();
      }
      
      // 注册清理钩子
      ctx.on('dispose', dispose);
    };
    
    return module.exports;
  }
});
