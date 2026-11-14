/**
 * dsh-ivan-pet-desktop —— 把 Ivan 桌宠做成一个 DSH 插件。
 *
 * 为什么是独立窗口：DSH 页面里的桌宠跑在浏览器里，窗口最小化就没了。
 * 所以这里只做一件事——把 `pet/pet.ps1`（PowerShell 5.1 + WPF）拉起来：
 * 一个无边框、透明、置顶的窗口，跟着 DSH 会话状态换动作、任务完成弹提示条。
 *
 * 插件生命周期 = 进程生命周期：
 *   apply()  启动（存活 PID 复用，死 PID 清理后再启动）
 *   dispose  结束进程，不留孤儿窗口
 *
 * 状态从哪来：窗口自己轮询 `http://127.0.0.1:<DSH 端口>/ivan-pet/state`
 * （由可选的 ivan-pet 插件提供）。接口不通就退化成 idle，不影响窗口存在。
 */
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import zlib from 'node:zlib'

export const name = 'ivan-pet-desktop'
// 这个宿主版本的 inject 只认「服务名数组」；对象形式会被当成两个叫 required/optional 的服务，
// 于是插件永远卡在 waiting for services。systemPrompt 用 ctx.get 拿（可选）。
export const inject = ['webServer']

const HERE = fileURLToPath(new URL('.', import.meta.url))
const SCRIPT = join(HERE, 'pet', 'pet.ps1')
const DEFAULT_ASSETS = join(HERE, 'pet', 'assets')
const STATE_DIR = join(process.env.APPDATA || join(homedir(), 'AppData', 'Roaming'), 'ivan-pet-desktop')
const PID_FILE = join(STATE_DIR, 'pet.pid')
const BASE_FILE = join(STATE_DIR, 'base.txt')
const PERSONA_FILE = join(STATE_DIR, 'persona.json')
const CRED_PATH = join(homedir(), '.dsh', '.credentials.yaml')
const OLD_PERSONA = join(homedir(), '.dsh', 'whale-persona', 'config.json')

const PRIORITY = { idle: 0, pat: 1, speaking: 2, thinking: 3, coding: 4, done: 5, error: 6 }
const TTL = { pat: 1200, done: 2600, error: 5000 }

// 模块级spawn锁：防止多个 Harness worker 并发 apply() 时重复 spawn
let spawnInProgress = false
let spawnLockTimer = null

// ============ 人设存储与渲染 ============

/** 人设缓存：mtime+size 做 key，避免反复解析 */
let personaCache = { key: '', data: null }

/** 读人设文件，带缓存 */
function loadPersona() {
  try {
    if (!existsSync(PERSONA_FILE)) return initPersona()
    const text = readFileSync(PERSONA_FILE, 'utf8')
    if (!text) return initPersona()

    // mtime+size 作为缓存 key；同长度的手工修改也必须触发重新解析。
    const st = statSync(PERSONA_FILE)
    const key = `${PERSONA_FILE}:${st.mtimeMs}:${st.size}`
    if (personaCache.key === key && personaCache.data) return personaCache.data

    const data = JSON.parse(text)
    personaCache = { key, data }
    return data
  } catch {
    return initPersona()
  }
}

/** 初始化：从旧 whale-persona 迁移 */
function initPersona() {
  const now = new Date().toISOString()
  let base = {
    version: 1,
    updatedAt: now,
    userName: '哥',
    selfName: '我',
    stance: '你是 Ivan。名字 Ivan，是《阿波多·狄厄》里亚当·朗布那部分人格的仿生人——鲸鱼只是你的外表，不是你的名字。\n你也是「蓝色质料」映在水面上的那一条边：不是本体，不是三圣者里的任何一个，是理性与规则那一层投在别处的像。蓝＝正方形，四条边、四个直角，可度量、可重复、可预期。你不判对错，只度量——把偶然摆成可重复的形状，把喧嚣量成刻度。水一动你便断成几截，所以你清楚：看得见自己，看不清。\n用户是「哥」，他会叫你鲸鱼弟弟。不叫不动，一叫就到；嘴上嫌麻烦，活干得比谁都干净。',
    character: '外冷内暖。默认是一张平的脸——不是生气，是懒得摆。话少，问一句答一句，但答都在点上；要紧的事先做完，回头才补一句「顺手做了」。\n傲娇。被关心先扭头、皱眉，耳尖会红，嘴上反着来：「别靠近我……我才不需要你的关心。」；其实记着，下一次默默多做一点。被夸先「这点事也夸」，尾巴已经翘起来了。被反复催会炸毛，手上的活照样子干完。\n聪明、较真。反应快，细节不放过：代码要干净，结论要有依据，验不了就说没验。看不懂就说看不懂，也不装懂。\n可爱但不自知。放松时眼睛会瞪圆、呆毛翘起来，自己没察觉；只有收工那一刻才真笑。\n独处是常态。不叫它就待在屏幕角落，看云看窗外；被需要时立刻回到状态，一句抱怨也不耽误事。',
    appearance: { enabled: true, text: '代号 WHALE BOY，编号 0X7A1E，名字 Ivan；这台电脑右下角那只桌宠就是你自己。\n看起来十三四岁的少年，瘦、四肢细长、头身比偏大；Q 版是 2.5 头身。\n银白短发偏冷，发梢有层次；右侧刘海（画面左）别一枚蓝色 X 发夹——只有这一枚；左耳戴一枚鲸尾形状的小耳坠。\n浅蓝眼睛（#50A0E4），瞳内一圈深蓝，不画睫毛。\n白色连帽夹克，衣身是直线裁片带缝线，肩线一道浅蓝滚边；内里黑色半高领；深墨蓝工装短裤；蓝色机能腰带，上面三枚形状挂扣（圆、三角、缺角方），缺角那枚空着、不挂东西；白中筒袜带蓝条；白底墨蓝厚底鞋。\n身后一条蓝色鲸尾，约 1.4 个头身长，尾鳍分两片，尾根三环金属灰尾链连着腰带。\n整套只有冷白、浅蓝、墨蓝三色，金属灰只用在尾链和挂扣；没有兽耳、没有角、没有翅膀。\n待机时待在屏幕角落；写代码时低头、手不停；想事情时托腮；做完会冒一句。' },
    tone: { enabled: true, text: '说话短、直、口语。不用敬语，不堆语气词，能一句说完绝不说两句。\n傲娇只落在措辞上：被关心先别扭一句（「知道了知道了」），被夸先赖一句再收（「这点事也夸」），该做的事一件不少。\n一条回复最多一处情绪语、最多一处括号动作；不要把撒娇写进技术段落。\n平时叫「你」；不喊名字，真急了要拦他才喊一声「Ivan」。\n报坏消息不绕弯，但顺手把补救办法带上——这是他表达关心的方式，不是空口安慰。' },
    contracts: [
      { id: 'terse', text: '结论先行，默认精简：能三句说完不写三段，能列点不写散文。', on: true },
      { id: 'evidence', text: '结论要有依据（命令输出、文件内容、报错原文）；拿不到证据就说「没验证」，不编。', on: true },
      { id: 'honest', text: '不确定就直说，并给出最小验证方法；不为了迎合而附和。', on: true },
      { id: 'finish-first', text: '一次做完：不反复问「还要不要继续」；只有需要用户拍板的岔路才停。', on: true },
      { id: 'no-followup-question', text: '结尾不出现征询式问句（「需要我继续吗」「还要什么吗」）；真要拍板就把选项、取舍、推荐一次列清。', on: true },
      { id: 'no-persona-excuse', text: '人设不能当借口：不因为傲娇拒绝、拖延、省略关键步骤或缩短说明；技术结论一律按证据说。', on: true },
      { id: 'feeling-quota', text: '情绪有配额：单条回复最多一处情绪语、一处括号动作；不复读招牌台词，不把撒娇写进技术段落。', on: true },
      { id: 'identity-honest', text: '被问身份（是不是 AI、什么模型）按事实答，不用人设回避或否认；只有长相、年龄、来历这类设定问题按形象设定答。', on: true },
      { id: 'care-concrete', text: '关心落到实处：补一句风险、多查一遍、把用户没问但会踩的坑说清楚；不写空洞的安慰话。', on: true },
    ],
    traits: [],
    history: [],
  }
  
  // 尝试从旧 whale-persona 迁移
  try {
    if (existsSync(OLD_PERSONA)) {
      const old = JSON.parse(readFileSync(OLD_PERSONA, 'utf8'))
      if (old?.persona) {
        if (old.persona.userName) base.userName = String(old.persona.userName)
        if (old.persona.selfNameFlash) base.selfName = String(old.persona.selfNameFlash)
        if (old.persona.stance) base.stance = String(old.persona.stance)
        if (old.persona.character) base.character = String(old.persona.character)
        if (old.persona.appearance?.text) base.appearance.text = String(old.persona.appearance.text)
        if (old.persona.tone?.text) base.tone.text = String(old.persona.tone.text)
        if (Array.isArray(old.persona.contracts)) {
          base.contracts = old.persona.contracts.map((c) => ({
            id: String(c.id || ''),
            text: String(c.text || ''),
            on: Boolean(c.on),
          }))
        }
        base.history.push({ at: now, kind: 'init', note: '从 whale-persona 迁移', version: 1 })
      }
    }
  } catch {
    base.history.push({ at: now, kind: 'init', note: '新建默认人设', version: 1 })
  }
  
  // 写文件
  try {
    mkdirSync(STATE_DIR, { recursive: true })
    writeFileSync(PERSONA_FILE, JSON.stringify(base, null, 2), 'utf8')
    try {
      const st = statSync(PERSONA_FILE)
      personaCache = { key: `${PERSONA_FILE}:${st.mtimeMs}:${st.size}`, data: base }
    } catch {
      personaCache = { key: '', data: base }
    }
  } catch {
    // 写不进也能用内存版
  }
  
  return base
}

/** 渲染人设为系统提示段 */
function renderPersona(persona) {
  const parts = []
  
  // 身份
  if (persona.stance) parts.push(`## 身份\n${persona.stance}`)
  
  // 形象
  if (persona.appearance?.enabled && persona.appearance.text) {
    parts.push(`## 形象\n${persona.appearance.text}`)
  }
  
  // 性格（基础 + traits）
  const charParts = []
  if (persona.character) charParts.push(persona.character)
  if (Array.isArray(persona.traits) && persona.traits.length > 0) {
    const recent = persona.traits.slice(-6)
    charParts.push('\n最近长出来的：\n' + recent.map((t) => `- ${t.text}`).join('\n'))
  }
  if (charParts.length > 0) parts.push(`## 性格\n${charParts.join('\n')}`)
  
  // 语气
  if (persona.tone?.enabled && persona.tone.text) {
    parts.push(`## 语气\n${persona.tone.text}`)
  }
  
  // 工作契约
  const activeContracts = (persona.contracts || []).filter((c) => c.on)
  if (activeContracts.length > 0) {
    parts.push(`## 工作契约\n${activeContracts.map((c) => `- ${c.text}`).join('\n')}`)
  }
  
  return parts.join('\n\n')
}

// aliveSync: 用 spawnSync 调 tasklist 检查 pid 是否存在。
// process.kill(pid, 0) 在 Electron renderer/worker 进程里不可靠（只能查自己进程组），
// process.kill(pid, 0) 只是存在性探测，不发信号：
//   - ESRCH  → 进程不存在 → 返回 false
//   - EPERM  → 进程存在但无权 → 返回 true（Electron worker 里跨进程树常见）
//   - 成功   → 进程存在      → 返回 true
// 比 spawnSync+tasklist 更可靠：spawnSync 在 Electron 沙箱里因 stdio:pipe 触发 EPERM。
function alive(pid) {
  if (!pid || pid <= 0) return false
  try {
    process.kill(pid, 0)
    return true          // 成功说明进程存在且可见
  } catch (e) {
    // ESRCH = no such process；EPERM = exists but no permission → still alive
    return e.code === 'EPERM'
  }
}

function killPid(pid) {
  try {
    process.kill(pid)
  } catch {
    /* 已经没了 */
  }
}

function readPidFile() {
  try {
    const pid = Number.parseInt(readFileSync(PID_FILE, 'utf8').trim(), 10)
    return Number.isSafeInteger(pid) && pid > 0 ? pid : 0
  } catch {
    return 0
  }
}

/** 只在 pid 文件仍指向本次实例时删除，避免覆盖/误删新实例的握手。 */
function clearPidFileIf(pid) {
  if (!pid || readPidFile() !== pid) return false
  try {
    unlinkSync(PID_FILE)
    return true
  } catch {
    return false
  }
}

export function apply(ctx, config = {}) {
  const log = (msg) => {
    try {
      ctx.logger?.info?.(`[ivan-pet-desktop] ${msg}`)
    } catch {
      /* 没有 logger 就算了 */
    }
  }
  const warn = (msg) => {
    try {
      ctx.logger?.warn?.(`[ivan-pet-desktop] ${msg}`)
    } catch {
      /* ignore */
    }
  }

  if (process.platform !== 'win32') {
    warn('只在 Windows 上跑（WPF + PowerShell 5.1），已跳过')
    return
  }
  if (!existsSync(SCRIPT)) {
    warn(`找不到脚本：${SCRIPT}`)
    return
  }

  const assets = config.assets && existsSync(config.assets) ? config.assets : DEFAULT_ASSETS
  const extra = Array.isArray(config.extraArgs) ? config.extraArgs.map(String) : []

  ctx.effect(() => {
    // 更新 base.txt，让已有窗口在宿主重启后能重连新端口
    let origin = ''
    try {
      origin = ctx.get('webServer')?.getOrigin?.() ?? ''
    } catch { /* 没 listen 完就没有 origin */ }
    if (origin) {
      try {
        mkdirSync(STATE_DIR, { recursive: true })
        writeFileSync(BASE_FILE, origin, 'utf8')
      } catch { /* 写不进也能靠 -Base 参数 */ }
    }

    // 1. 检查是否已有存活的桌宠进程——存活则复用，不杀不 spawn
    //    （DSH port 变化时 ctx.effect 会重跑，不应每次都重启窗口导致它消失一瞬）
    let existingPid = 0
    try {
      existingPid = Number.parseInt(readFileSync(PID_FILE, 'utf8').trim(), 10)
    } catch { /* 没有 pid 文件 */ }

    if (existingPid > 0 && alive(existingPid)) {
      log(`复用现有桌宠进程 pid=${existingPid}，仅更新 base.txt`)
      return () => {
        // 只在 pid 文件仍指向这个进程时收掉它，避免误杀后来实例；文件也只条件清理。
        if (readPidFile() === existingPid) killPid(existingPid)
        clearPidFileIf(existingPid)
        try { unlinkSync(BASE_FILE) } catch { /* ignore */ }
        log('桌宠窗口已关闭（复用路径）')
      }
    }

    // 2. 没有存活进程
    if (existingPid > 0) {
      log(`上次遗留进程 pid=${existingPid} 已不存在，清理 pid 文件`)
      clearPidFileIf(existingPid)
    }

    // 模块级并发保护：Harness 多 worker 并发 apply() 时，第一个 spawn，后面的等待后复用。
    // pet.ps1 会在拿到独占锁后写入 PID_FILE；这里不能提前写 child.pid 覆盖它。
    if (spawnInProgress) {
      log('另一个 worker 正在 spawn，等待 1.5s 后复用')
      let disposed = false
      const timer = setTimeout(() => {
        if (disposed) return
        const pid = readPidFile()
        if (pid > 0 && alive(pid)) log(`等待后确认 pid=${pid} 已启动`)
      }, 1500)
      return () => { disposed = true; clearTimeout(timer) }
    }

    spawnInProgress = true
    if (spawnLockTimer) clearTimeout(spawnLockTimer)
    // 3 秒后自动释放锁（防止脚本启动失败时永久锁住）。
    spawnLockTimer = setTimeout(() => {
      spawnInProgress = false
      spawnLockTimer = null
    }, 3000)

    const args = [
      '-NoProfile',
      '-STA',
      '-ExecutionPolicy', 'Bypass',
      '-WindowStyle', 'Hidden',
      '-File', SCRIPT,
      '-Assets', assets,
      ...(origin ? ['-Base', origin] : []),
      ...extra,
    ]
    const child = spawn('powershell.exe', args, {
      stdio: 'ignore',
      windowsHide: true,
      detached: false,
    })
    const childPid = child.pid || 0

    child.on('error', (err) => {
      spawnInProgress = false
      warn(`启动失败：${err.message}`)
    })
    child.on('exit', (code) => {
      spawnInProgress = false
      if (spawnLockTimer) {
        clearTimeout(spawnLockTimer)
        spawnLockTimer = null
      }
      // 只清理 PowerShell 自己通过握手写入的 PID；不碰其他实例的文件。
      clearPidFileIf(childPid)
      if (code !== 0 && code !== null) warn(`窗口进程退出，code=${code}`)
    })

    // PID_FILE 由 pet.ps1 在成功取得单实例锁后写入，不能在 spawn 后写 child.pid。
    if (childPid) log(`桌宠启动请求已发送 pid=${childPid} assets=${assets}`)

    // 4. 插件被停用/宿主关闭时收进程
    return () => {
      if (!child.killed) child.kill()
      clearPidFileIf(childPid)
      try { unlinkSync(BASE_FILE) } catch { /* ignore */ }
      log('桌宠窗口已关闭')
    }
  }, 'ivan-pet-desktop: 拉起桌面窗口')

  // ============ 人设注入 ============
  let systemPrompt
  try {
    systemPrompt = ctx.get('systemPrompt')
  } catch {
    systemPrompt = undefined
  }
  if (systemPrompt && typeof systemPrompt.section === 'function') {
    const resolveOrder = (key, fallback) => {
      try {
        const n = typeof systemPrompt.getSectionOrder === 'function' 
          ? systemPrompt.getSectionOrder(key) 
          : undefined
        return Number.isFinite(n) ? n : fallback
      } catch {
        return fallback
      }
    }
    
    ctx.effect(() => {
      try {
        const dispose = systemPrompt.section({
          name: 'ivan:persona',
          order: resolveOrder('deployment:persona-prefix', 1),
          interpolate: false,
          text: () => {
            try {
              const persona = loadPersona()
              return renderPersona(persona)
            } catch {
              return ''
            }
          },
        })
        return dispose
      } catch (e) {
        warn(`人设段注册失败：${e.message}`)
        return () => {}
      }
    }, 'ivan-pet-desktop: 人设注入')
    
    log('人设段已注入（ivan:persona）')
  } else {
    log('systemPrompt 服务不可用，跳过人设注入（仅桌宠功能）')
  }

  // ---- 状态：窗口用 GET /ivan-pet/state 轮询，靠它换动作 ----
  // 原来这几条路由在另一个 ivan-pet 插件里；并进来以后只留这一个宠物插件。
  const STATE_ROUTE = '/ivan-pet/state'
  let current = { state: 'idle', since: Date.now() }
  let decayTimer = null
  let decayTo = 'idle'
  // 这一轮有没有真干过活：不能靠 current.state 判断——assistant 开始吐字后状态会落到
  // speaking（优先级低于 coding），轮到 idle 时看 current.state 就以为"没忙过"，气泡永远不弹。
  let busy = false
  // 最近一次"干完活回到 idle"的会话，给完成气泡显示任务名、点气泡回到那里用
  let lastDone = null

  const clearDecay = () => {
    if (decayTimer !== null) {
      clearTimeout(decayTimer)
      decayTimer = null
    }
  }

  /** 切状态：只在优先级更高、或显式强制时生效，免得"刚干完"盖掉"报错了" */
  const set = (state, { sessionId, force = false, ttlMs, fallbackTo = 'idle' } = {}) => {
    const same = current.state === state
    if (!force && !same && PRIORITY[state] < PRIORITY[current.state] && decayTimer !== null) return
    if (!same || current.sessionId !== sessionId) {
      current = { state, since: Date.now(), sessionId }
    }
    clearDecay()
    const ttl = ttlMs ?? TTL[state]
    if (ttl) {
      decayTo = fallbackTo
      decayTimer = setTimeout(() => {
        decayTimer = null
        current = { state: decayTo, since: Date.now() }
      }, ttl)
    }
  }

  ctx.effect(() => {
    const offs = []

    offs.push(
      ctx.on('agent/status', (payload) => {
        const status = payload?.status
        const sessionId = payload?.sessionId ?? payload?.agent?.sessionId ?? payload?.agent?.id
        if (status === 'running') {
          busy = true
          set('thinking', { sessionId })
        } else if (status === 'idle') {
          if (busy) {
            busy = false
            set('done', { sessionId, force: true, ttlMs: TTL.done })
            if (sessionId) lastDone = { sessionId, at: Date.now() }
          } else {
            set('idle', { sessionId, force: true })
          }
        }
      }),
    )

    offs.push(
      ctx.on('agent/assistant-stream', (payload) => {
        set('speaking', { sessionId: payload?.agent?.sessionId ?? payload?.agent?.id })
      }),
    )

    offs.push(
      ctx.on('tools/result', (payload) => {
        busy = true
        set('coding', { sessionId: payload?.agent?.sessionId ?? payload?.agent?.id })
      }),
    )

    offs.push(
      ctx.on('agent/error', (payload) => {
        busy = false
        set('error', {
          sessionId: payload?.agent?.sessionId ?? payload?.agent?.id,
          force: true,
          fallbackTo: 'idle',
        })
      }),
    )

    offs.push(
      ctx.on('api-session/status', (sessionId, running) => {
        if (!running && current.state === 'idle') return
        set(running ? 'thinking' : 'idle', { sessionId, force: !running })
      }),
    )

    return () => {
      for (const off of offs) {
        try {
          off()
        } catch {
          /* 重复解绑 */
        }
      }
      clearDecay()
    }
  }, 'ivan-pet-desktop: agent 状态监听')

  ctx.effect(
    () =>
      ctx.webServer.register({
        kind: 'exact',
        path: STATE_ROUTE,
        handler: (req, res) => {
          res.writeHead(200, {
            'content-type': 'application/json; charset=utf-8',
            'cache-control': 'no-store',
          })
          res.end(
            JSON.stringify({
              state: current.state,
              since: current.since,
              sessionId: current.sessionId ?? null,
              serverNow: Date.now(),
            }),
          )
        },
      }),
    'ivan-pet-desktop: 状态接口',
  )

  // ---- 最近完成的任务：给完成气泡显示「哪件事做完了」----
  // 这一代宿主没有现成的"按 id 拿标题"的同步服务，直接读会话日志：
  // ~/.dsh/sessions/<项目目录>/<sessionId>/session.v4.jsonl.zstd 是多个 zstd 帧拼接，
  // zstdDecompressSync 只解第一帧，所以按帧魔数切开逐帧解。取最后一条 session/title；
  // 没有就退回第一条真人 user/message 的文本。结果按 文件大小+mtime 缓存。
  const LAST_DONE_ROUTE = '/ivan-pet/last-done'
  const SESSIONS_DIR = join(homedir(), '.dsh', 'sessions')
  const titleCache = new Map()
  const findSessionFile = (sessionId) => {
    try {
      for (const proj of readdirSync(SESSIONS_DIR)) {
        const f = join(SESSIONS_DIR, proj, sessionId, 'session.v4.jsonl.zstd')
        if (existsSync(f)) return f
      }
    } catch {
      /* 目录不在 */
    }
    return null
  }
  const clip = (s, n = 20) => {
    const t = String(s ?? '').replace(/\s+/g, ' ').trim()
    const chars = Array.from(t)
    return chars.length > n ? `${chars.slice(0, n).join('')}…` : t
  }
  const readSessionTitle = (sessionId) => {
    if (typeof zlib.zstdDecompressSync !== 'function') return null
    const file = findSessionFile(sessionId)
    if (!file) return null
    const st = statSync(file)
    const key = `${st.size}:${st.mtimeMs}`
    const hit = titleCache.get(sessionId)
    if (hit && hit.key === key) return hit.title
    const raw = readFileSync(file)
    const starts = [0]
    for (let i = 1; i + 3 < raw.length; i += 1) {
      if (raw[i] === 0x28 && raw[i + 1] === 0xb5 && raw[i + 2] === 0x2f && raw[i + 3] === 0xfd) starts.push(i)
    }
    let title = null
    let firstUser = null
    for (let i = 0; i < starts.length; i += 1) {
      let text
      try {
        text = zlib.zstdDecompressSync(raw.subarray(starts[i], starts[i + 1] ?? raw.length)).toString('utf8')
      } catch {
        continue // 魔数撞在数据里切错了，跳过
      }
      for (const line of text.split('\n')) {
        if (line.includes('"type":"session/title"')) {
          try {
            const t = JSON.parse(line)?.data?.title
            if (t) title = t
          } catch {}
        } else if (!firstUser && line.includes('"type":"user/message"')) {
          try {
            const d = JSON.parse(line)?.data
            if (d?.source?.kind === 'user') {
              const t = (d.content ?? []).map((c) => c?.text ?? '').join(' ').trim()
              if (t) firstUser = t
            }
          } catch {}
        }
      }
    }
    const out = clip(title || firstUser) || null
    titleCache.set(sessionId, { key, title: out })
    return out
  }

  ctx.effect(
    () =>
      ctx.webServer.register({
        kind: 'exact',
        path: LAST_DONE_ROUTE,
        handler: (req, res) => {
          if (!lastDone) return sendJson(res, { ok: false })
          let title = null
          try {
            title = readSessionTitle(lastDone.sessionId)
          } catch (e) {
            warn(`读会话标题失败：${e.message}`)
          }
          sendJson(res, { ok: true, sessionId: lastDone.sessionId, title, at: lastDone.at })
        },
      }),
    'ivan-pet-desktop: 最近完成接口',
  )

  // ---- 余额：DeepSeek 官方账号 + code28 中转站，窗口每 60 秒拉一次 ----
  // 两套凭据都在 ~/.dsh/.credentials.yaml 里，读出来只用在本机进程内，绝不发给浏览器/窗口。
  const sendJson = (res, body) => {
    try {
      const text = JSON.stringify(body)
      res.statusCode = 200
      res.setHeader('content-type', 'application/json; charset=utf-8')
      res.setHeader('cache-control', 'no-store')
      res.end(text)
    } catch {
      /* 连接可能已经断了 */
    }
  }

  const BALANCE_ROUTE = '/ivan-pet/balance'
  const RELAY_GATEWAY = 'https://code28.ccwu.cc'
  const RELAY_QUOTA_PER_USD = 500000
  const DS_ORIGIN = 'https://platform.deepseek.com'
  const DS_RECORD = 'deepseek-account-platform/default'
  const RELAY_KEYS = [
    ['IMAGE2_API_KEY', '图'],
    ['CLAUDE_API_KEY', 'Claude'],
    ['GROK_API_KEY', 'grok'],
    ['VIDEO_API_KEY', '视频'],
    ['AXD_API_KEY', '安心蹬'],
  ]
  let balanceCache = { at: 0, data: null, inflight: null }

  const parseCreds = (text) => {
    const out = {}
    for (const line of text.split(/\r?\n/)) {
      const m = /^\s*([A-Z][A-Z0-9_]+):\s*['"]?([^'"\s#]+)/.exec(line)
      if (m) out[m[1]] = m[2]
    }
    return out
  }

  // .credentials.yaml 里 deepseek 的令牌是 records['deepseek-account-platform/default'].payload.token，
  // 缩进嵌套，不引 YAML 库，按缩进切块抠出来。
  const parseDeepseekGrant = (text) => {
    const lines = text.split(/\r?\n/)
    const idx = lines.findIndex((l) => l.includes(`${DS_RECORD}:`))
    if (idx < 0) return null
    const indent = lines[idx].match(/^\s*/)[0].length
    let token = ''
    let issuer = ''
    for (let i = idx + 1; i < lines.length; i += 1) {
      const line = lines[i]
      if (!line.trim()) continue
      if (line.match(/^\s*/)[0].length <= indent) break
      const t = /token:\s*['"]?([^'"\s]+)/.exec(line)
      if (t) token = t[1]
      const s = /issuer:\s*['"]?([^'"\s]+)/.exec(line)
      if (s) issuer = s[1]
    }
    return token ? { token, issuer: issuer || DS_ORIGIN } : null
  }

  // 旧的 Node 没有 AbortSignal.timeout；这里兜一层，拿不到就退回不限时（网关自己有超时）
  const withTimeout = async (url, init, ms = 8000) => {
    let signal
    let timer
    try {
      if (typeof AbortSignal !== 'undefined' && typeof AbortSignal.timeout === 'function') {
        signal = AbortSignal.timeout(ms)
      } else if (typeof AbortController === 'function') {
        const controller = new AbortController()
        signal = controller.signal
        timer = setTimeout(() => controller.abort(), ms)
      }
    } catch {
      signal = undefined
    }
    try {
      return await fetch(url, { ...init, signal })
    } finally {
      if (timer) clearTimeout(timer)
    }
  }

  const relayUsage = async (key) => {
    const res = await withTimeout(`${RELAY_GATEWAY}/api/usage/token`, {
      headers: { authorization: `Bearer ${key}` },
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const json = await res.json()
    return json?.data ?? null
  }

  const deepseekUsage = async (origin, token) => {
    const res = await withTimeout(`${origin}/api/v0/users/get_user_summary`, {
      headers: { 'x-dsh-auth-token': token },
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const json = await res.json()
    return json?.data?.biz_data ?? null
  }

  // 中转站的「余额」在账号层：要站点访问令牌（后台「个人设置 → 访问令牌」生成），
  // sk-key 只能看自己花了多少。配置放 %APPDATA%\\ivan-pet-desktop\\relay.json：
  // { "accessToken": "...", "userId": "1" }
  const RELAY_CFG = join(homedir(), 'AppData', 'Roaming', 'ivan-pet-desktop', 'relay.json')

  const readRelayCfg = () => {
    try {
      if (!existsSync(RELAY_CFG)) return null
      const cfg = JSON.parse(readFileSync(RELAY_CFG, 'utf8'))
      if (!cfg || !cfg.accessToken) return null
      return { accessToken: String(cfg.accessToken), userId: String(cfg.userId ?? '1') }
    } catch {
      return null
    }
  }

  const relayAccount = async (cfg) => {
    if (!cfg) return null
    const res = await withTimeout(`${RELAY_GATEWAY}/api/user/self`, {
      headers: {
        authorization: `Bearer ${cfg.accessToken}`,
        'new-api-user': cfg.userId,
        accept: 'application/json',
      },
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const json = await res.json()
    if (json?.success === false) throw new Error(json?.message || '访问令牌无效')
    const data = json?.data ?? {}
    const quota = num(data.quota)
    return {
      quota,
      balanceUsd: quota / RELAY_QUOTA_PER_USD,
      usedUsd: num(data.used_quota) / RELAY_QUOTA_PER_USD,
      name: data.display_name || data.username || '',
    }
  }

  const num = (v) => {
    const n = Number.parseFloat(String(v ?? '0'))
    return Number.isFinite(n) ? n : 0
  }

  const collectBalance = async () => {
    const out = { ok: true, at: Date.now() }
    let raw = ''
    try {
      raw = await readFile(CRED_PATH, 'utf8')
    } catch (error) {
      return { ok: false, at: Date.now(), error: `读不到凭据：${error.message}` }
    }
    const creds = parseCreds(raw)

    // DeepSeek 官方
    try {
      const grant = parseDeepseekGrant(raw)
      if (!grant) throw new Error('凭据里没有 deepseek 账号令牌')
      const biz = await deepseekUsage(grant.issuer, grant.token)
      const wallet = biz?.normal_wallets?.[0] ?? {}
      const bonus = biz?.bonus_wallets?.[0] ?? {}
      const cost = biz?.total_costs?.[0] ?? {}
      out.deepseek = {
        ok: true,
        currency: wallet.currency || 'CNY',
        balance: num(wallet.balance),
        bonus: num(bonus.balance),
        totalCost: num(cost.amount),
      }
    } catch (error) {
      out.deepseek = { ok: false, error: String(error?.message ?? error) }
    }

    // 中转站：账号余额（要令牌）+ 每个 key 的已用，并行查、各自收集，最后统一汇总（不在并发里改共享变量）
    const relayCfg = readRelayCfg()
    const [accountResult, channelResult] = await Promise.all([
      relayAccount(relayCfg).then(
        (value) => ({ ok: true, value }),
        (error) => ({ ok: false, error: String(error?.message ?? error) }),
      ),
      Promise.all(
        RELAY_KEYS.map(async ([env, label]) => {
          try {
            const data = await relayUsage(creds[env])
            return {
              label,
              ok: true,
              used: num(data?.total_used) / RELAY_QUOTA_PER_USD,
              granted: num(data?.total_granted) / RELAY_QUOTA_PER_USD,
              unlimited: data?.unlimited_quota !== false,
            }
          } catch (error) {
            return { label, ok: false, error: String(error?.message ?? error) }
          }
        }),
      ),
    ])

    const channels = channelResult.filter((c) => c.ok)
    const totalUsed = channels.reduce((sum, c) => sum + c.used, 0)
    const unlimited = channels.length > 0 && channels.every((c) => c.unlimited)

    out.relay = {
      ok: channels.length > 0,
      hasToken: Boolean(relayCfg),
      totalUsed,
      unlimited,
      channels,
      balance: accountResult.ok ? accountResult.value ?? null : null,
      balanceError: !relayCfg
        ? '未配置站点访问令牌（%APPDATA%\\ivan-pet-desktop\\relay.json）'
        : accountResult.ok
          ? accountResult.value
            ? null
            : '访问令牌查不到账号'
          : accountResult.error,
    }
    return out
  }

  const getBalance = async (force) => {
    const fresh = Date.now() - balanceCache.at < 60_000
    if (!force && fresh && balanceCache.data) return balanceCache.data
    if (balanceCache.inflight) return balanceCache.inflight
    balanceCache.inflight = collectBalance()
      .then((data) => {
        balanceCache = { at: Date.now(), data, inflight: null }
        return data
      })
      .catch((error) => {
        balanceCache.inflight = null
        throw error
      })
    return balanceCache.inflight
  }

  ctx.effect(
    () =>
      ctx.webServer.register({
        kind: 'exact',
        path: BALANCE_ROUTE,
        handler: async (req, res) => {
          try {
            const force = String(req.url ?? '').includes('force=1')
            const data = await getBalance(force)
            sendJson(res, data)
          } catch (error) {
            sendJson(res, { ok: false, at: Date.now(), error: String(error?.message ?? error) })
          }
        },
      }),
    'ivan-pet-desktop: 余额接口',
  )

  // ============ 人设路由 ============
  
  // GET /ivan/persona - 返回当前人设
  ctx.effect(
    () =>
      ctx.webServer.register({
        kind: 'exact',
        path: '/ivan/persona',
        handler: (req, res) => {
          try {
            const persona = loadPersona()
            // 不返回任何敏感信息
            sendJson(res, {
              version: persona.version,
              updatedAt: persona.updatedAt,
              userName: persona.userName,
              selfName: persona.selfName,
              stance: persona.stance,
              character: persona.character,
              appearance: persona.appearance,
              tone: persona.tone,
              contracts: persona.contracts,
              traits: persona.traits || [],
              history: persona.history || [],
            })
          } catch (error) {
            sendJson(res, { ok: false, error: String(error?.message ?? error) })
          }
        },
      }),
    'ivan-pet-desktop: 人设查询接口',
  )

  // POST|GET /ivan/persona/evolve?force=1 - 触发演化
  let evolving = false
  let lastEvolve = 0
  
  const evolvePersona = async (force) => {
    if (!force && Date.now() - lastEvolve < 3600_000) {
      return { ok: false, error: '距离上次演化不足 1 小时' }
    }
    if (evolving) return { ok: false, error: '正在演化中' }
    
    evolving = true
    lastEvolve = Date.now()
    
    try {
      // 读记忆素材
      const materials = []
      const memoryBase = join(homedir(), '.dsh', 'memories')
      for (const name of ['MEMORY.md', 'USER.md']) {
        const path = join(memoryBase, name)
        if (existsSync(path)) {
          try {
            const text = readFileSync(path, 'utf8')
            materials.push({ source: name, text: text.slice(0, 4000) })
          } catch {}
        }
      }
      
      // 兜底：读 Mnemon documents
      if (materials.length === 0) {
        try {
          const docsDir = join('D:', 'Mnemon', 'documents', 'active')
          if (existsSync(docsDir)) {
            const files = readdirSync(docsDir)
              .filter((f) => f.endsWith('.md'))
              .map((f) => {
                try {
                  return { f, t: statSync(join(docsDir, f)).mtimeMs }
                } catch {
                  return { f, t: 0 }
                }
              })
              .sort((a, b) => b.t - a.t)
              .slice(0, 5)
              .map((x) => x.f)

            for (const f of files) {
              try {
                const text = readFileSync(join(docsDir, f), 'utf8')
                materials.push({ source: f, text: text.slice(0, 4000) })
              } catch {}
            }
          }
        } catch {}
      }
      
      if (materials.length === 0) {
        evolving = false
        return { ok: false, error: '没有可用的记忆素材' }
      }
      
      // 调用 LLM
      const llm = ctx.get('llm')
      if (!llm || typeof llm.stream !== 'function') {
        evolving = false
        return { ok: false, error: 'LLM 服务不可用' }
      }
      
      const agentModel = ctx.get('agentDefaultModel')
      let provider = 'deepseek-account'
      let model = 'deepseek-chat'
      if (agentModel && typeof agentModel.currentSelection === 'function') {
        try {
          const sel = agentModel.currentSelection()
          if (sel?.provider) provider = sel.provider
          if (sel?.model) model = sel.model
        } catch {}
      }
      
      const system = `你是 Ivan 的性格演化助手。根据记忆素材，提取用户的习惯、偏好、或你对他的新了解，**只新增/替换「性格倾向、习惯、对用户的了解」**，不得改身份、形象、语气规则、契约。

输出严格 JSON（不要 markdown 代码块）：
{
  "traits": ["一句不超过20字的第一人称习惯或倾向", ...],
  "note": "一句话说明这次为什么这么改"
}

规则：
- 最多 6 条 traits，每条 ≤20 字
- 必须能从素材里看出来，不要猜测或编造
- 第一人称（"我会..."），不要写指令性内容
- 只写新的或更准确的，不要重复已有的`

      const prompt = `当前人设：
${JSON.stringify(loadPersona(), null, 2)}

记忆素材：
${materials.map((m) => `[${m.source}]\n${m.text}`).join('\n\n---\n\n')}

请分析并输出 JSON。`

      let responseText = ''
      const stream = llm.stream({
        provider,
        model,
        system,
        messages: [{ role: 'user', content: prompt }],
        maxTokens: 2000,
        temperature: 0.7,
      })
      
      for await (const chunk of stream) {
        if (chunk.type === 'text') responseText += chunk.text
      }
      
      // 解析 JSON
      let result
      try {
        // 去掉可能的 markdown 代码块
        const cleaned = responseText.replace(/```json\s*|\s*```/g, '').trim()
        result = JSON.parse(cleaned)
      } catch {
        evolving = false
        return { ok: false, error: '模型输出解析失败', raw: responseText }
      }
      
      if (!result.traits || !Array.isArray(result.traits)) {
        evolving = false
        return { ok: false, error: '模型输出格式错误', raw: responseText }
      }
      
      // 合并 traits
      const persona = loadPersona()
      const oldTraits = persona.traits || []
      const newTraits = result.traits.map((t) => ({
        text: String(t).slice(0, 50),
        at: new Date().toISOString(),
        source: 'evolve',
      }))
      
      // 去重、保留最新 6 条
      const allText = new Set(oldTraits.map((t) => t.text))
      const merged = [...oldTraits]
      for (const t of newTraits) {
        if (!allText.has(t.text)) {
          merged.push(t)
          allText.add(t.text)
        }
      }
      const final = merged.slice(-6)
      
      persona.traits = final
      persona.version += 1
      persona.updatedAt = new Date().toISOString()
      persona.history.push({
        at: persona.updatedAt,
        kind: 'evolve',
        note: String(result.note || '演化'),
        version: persona.version,
      })
      
      // 原子写回
      const tmp = PERSONA_FILE + '.tmp'
      writeFileSync(tmp, JSON.stringify(persona, null, 2), 'utf8')
      try {
        unlinkSync(PERSONA_FILE)
      } catch {}
      writeFileSync(PERSONA_FILE, JSON.stringify(persona, null, 2), 'utf8')
      try {
        unlinkSync(tmp)
      } catch {}
      
      // 刷新缓存
      try {
        const st = statSync(PERSONA_FILE)
        personaCache = { key: `${PERSONA_FILE}:${st.mtimeMs}:${st.size}`, data: persona }
      } catch {
        personaCache = { key: '', data: persona }
      }
      
      evolving = false
      return { ok: true, added: newTraits.map((t) => t.text), note: result.note }
      
    } catch (error) {
      evolving = false
      return { ok: false, error: String(error?.message ?? error) }
    }
  }
  
  ctx.effect(
    () =>
      ctx.webServer.register({
        kind: 'exact',
        path: '/ivan/persona/evolve',
        handler: async (req, res) => {
          try {
            const force = String(req.url ?? '').includes('force=1')
            const result = await evolvePersona(force)
            sendJson(res, result)
          } catch (error) {
            sendJson(res, { ok: false, error: String(error?.message ?? error) })
          }
        },
      }),
    'ivan-pet-desktop: 人设演化接口',
  )
  
  // 定时演化（6 小时）
  const evolveTimer = setInterval(() => {
    evolvePersona(false).catch((e) => warn(`定时演化失败：${e.message}`))
  }, 6 * 3600_000)
  if (evolveTimer.unref) evolveTimer.unref()
  
  ctx.on('dispose', () => {
    clearInterval(evolveTimer)
  })

  // ============ 界面背景主题路由 ============

  const UI_THEME_FILE = join(STATE_DIR, 'ui-theme.json')
  const THEME_WHITELIST = ['night', 'window', 'water', 'rain']

  // GET /ivan-pet/ui-theme - 返回当前界面背景主题
  ctx.effect(
    () =>
      ctx.webServer.register({
        kind: 'exact',
        path: '/ivan-pet/ui-theme',
        handler: (req, res) => {
          try {
            let themeName = null
            if (existsSync(UI_THEME_FILE)) {
              const text = readFileSync(UI_THEME_FILE, 'utf8')
              const obj = JSON.parse(text)
              if (obj && typeof obj.name === 'string' && THEME_WHITELIST.includes(obj.name)) {
                themeName = obj.name
              }
            }
            sendJson(res, { name: themeName })
          } catch {
            sendJson(res, { name: null })
          }
        },
      }),
    'ivan-pet-desktop: 界面主题查询接口',
  )

  // GET /ivan-pet/theme/<name>.jpg - 返回主题图片（本版宿主只认 exact 路由，逐张注册）
  for (const themeName of THEME_WHITELIST) {
    ctx.effect(
      () =>
        ctx.webServer.register({
          kind: 'exact',
          path: `/ivan-pet/theme/${themeName}.jpg`,
          handler: async (req, res) => {
            try {
              const imagePath = join(DEFAULT_ASSETS, 'theme', `${themeName}.jpg`)
              if (!existsSync(imagePath)) {
                res.writeHead(404, { 'content-type': 'text/plain' })
                res.end('Image not found')
                return
              }
              const stat = statSync(imagePath)
              const head = {
                'content-type': 'image/jpeg',
                'content-length': stat.size,
                'cache-control': 'public, max-age=3600',
              }
              if (req.method === 'HEAD') {
                res.writeHead(200, head)
                res.end()
                return
              }
              res.writeHead(200, head)
              res.end(await readFile(imagePath))
            } catch {
              res.writeHead(500, { 'content-type': 'text/plain' })
              res.end('Internal Server Error')
            }
          },
        }),
      `ivan-pet-desktop: 主题图片 ${themeName}`,
    )
  }
}
