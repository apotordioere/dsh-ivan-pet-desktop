/**
 * dsh-ivan-pet-desktop —— 把 Ivan 桌宠做成一个 DSH 插件。
 *
 * 为什么是独立窗口：DSH 页面里的桌宠跑在浏览器里，窗口最小化就没了。
 * 所以这里只做一件事——把 `pet/pet.ps1`（PowerShell 5.1 + WPF）拉起来：
 * 一个无边框、透明、置顶的窗口，跟着 DSH 会话状态换动作、任务完成弹提示条。
 *
 * 插件生命周期 = 进程生命周期：
 *   apply()  启动（先清掉上次遗留的实例）
 *   dispose  结束进程，不留孤儿窗口
 *
 * 状态从哪来：窗口自己轮询 `http://127.0.0.1:<DSH 端口>/ivan-pet/state`
 * （由可选的 ivan-pet 插件提供）。接口不通就退化成 idle，不影响窗口存在。
 */
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'ivan-pet-desktop'
export const inject = ['webServer']

const HERE = fileURLToPath(new URL('.', import.meta.url))
const SCRIPT = join(HERE, 'pet', 'pet.ps1')
const DEFAULT_ASSETS = join(HERE, 'pet', 'assets')
const STATE_DIR = join(process.env.APPDATA || join(homedir(), 'AppData', 'Roaming'), 'ivan-pet-desktop')
const PID_FILE = join(STATE_DIR, 'pet.pid')
const BASE_FILE = join(STATE_DIR, 'base.txt')

const PRIORITY = { idle: 0, pat: 1, speaking: 2, thinking: 3, coding: 4, done: 5, error: 6 }
const TTL = { pat: 1200, done: 2600, error: 5000 }

function alive(pid) {
  if (!pid || pid <= 0) return false
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

function killPid(pid) {
  try {
    process.kill(pid)
  } catch {
    /* 已经没了 */
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
    // 1. 收掉上一次遗留的实例（宿主崩溃/强退都会留下进程）
    try {
      const old = Number.parseInt(readFileSync(PID_FILE, 'utf8').trim(), 10)
      if (alive(old)) {
        log(`结束上次遗留的桌宠进程 pid=${old}`)
        killPid(old)
      }
    } catch {
      /* 没有 pid 文件 */
    }

    // 2. 拉起窗口
    // 端口每次宿主重启都可能变，窗口靠进程名找端口并不可靠（实测找不到：HTTP 服务不在
    // "DeepSeek Harness" 进程名下），所以这里把 webServer 自己报的 origin 直接交给它。
    let origin = ''
    try {
      origin = ctx.get('webServer')?.getOrigin?.() ?? ''
    } catch {
      /* 没 listen 完就没有 origin，窗口会退回自己找 */
    }
    if (origin) {
      try {
        mkdirSync(STATE_DIR, { recursive: true })
        writeFileSync(BASE_FILE, origin, 'utf8')
      } catch {
        /* 写不进也能靠 -Base 参数 */
      }
    }

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

    child.on('error', (err) => warn(`启动失败：${err.message}`))
    child.on('exit', (code) => {
      if (code !== 0 && code !== null) warn(`窗口进程退出，code=${code}`)
    })

    if (child.pid) {
      try {
        mkdirSync(STATE_DIR, { recursive: true })
        writeFileSync(PID_FILE, String(child.pid), 'utf8')
      } catch {
        /* 写不进就不写，不影响窗口 */
      }
      log(`桌宠窗口已启动 pid=${child.pid} assets=${assets}`)
    }

    // 3. 插件被停用/宿主关闭时收进程
    return () => {
      if (!child.killed) child.kill()
      try {
        unlinkSync(PID_FILE)
      } catch {
        /* ignore */
      }
      try {
        unlinkSync(BASE_FILE)
      } catch {
        /* ignore */
      }
      log('桌宠窗口已关闭')
    }
  }, 'ivan-pet-desktop: 拉起桌面窗口')

  // ---- 状态：窗口用 GET /ivan-pet/state 轮询，靠它换动作 ----
  // 原来这几条路由在另一个 ivan-pet 插件里；并进来以后只留这一个宠物插件。
  const STATE_ROUTE = '/ivan-pet/state'
  let current = { state: 'idle', since: Date.now() }
  let decayTimer = null
  let decayTo = 'idle'

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
        const sessionId = payload?.agent?.sessionId ?? payload?.agent?.id
        if (status === 'running') {
          set('thinking', { sessionId })
        } else if (status === 'idle') {
          const wasBusy = PRIORITY[current.state] >= PRIORITY.coding
          if (wasBusy) set('done', { sessionId, force: true })
          else set('idle', { sessionId, force: true })
        }
      }),
    )

    offs.push(
      ctx.on('agent/assistant-stream', (payload) => {
        set('speaking', { sessionId: payload?.agent?.sessionId ?? payload?.agent?.id })
      }),
    )

    offs.push(ctx.on('tools/result', () => set('coding', {})))

    offs.push(
      ctx.on('agent/error', (payload) => {
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

  // ---- 对话：窗户里说的话，交给当前默认模型，用 Ivan 的口气回 ----
  // 用 ctx.get 拿可选服务：宿主没有 llm 时对话不可用，但窗口照常。
  const persona = [
    '你是 Ivan，一个被造出来的仿生人少年，外形十三四岁，银色短发、浅蓝色眼睛，身后有一条鲸尾。',
    '你在用户的桌面上陪着他。说话短、直、口语，一两句就够，最多 60 个字。',
    '语气外冷内暖，偶尔傲娇，但不说教、不卖萌、不用表情符号，不列条目。',
    '不要提自己是 AI 或模型，不要用"作为……"这类开头。',
  ].join('\n')

  const history = []

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

  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: '/ivan-pet/chat',
    handler: async (req, res) => {
      try {
        const url = new URL(req.url ?? '/', 'http://127.0.0.1')
        const text = (url.searchParams.get('text') ?? '').trim().slice(0, 600)
        if (!text) return sendJson(res, { ok: false, error: '空的' })

        const llm = ctx.get('llm')
        if (!llm) return sendJson(res, { ok: false, error: '宿主没有 llm 服务' })

        let selection = {}
        try {
          selection = ctx.get('agentDefaultModel')?.currentSelection?.() ?? {}
        } catch {
          /* 拿不到就用兜底 */
        }
        const provider = selection.provider || 'deepseek-account'
        const model = selection.model || 'deepseek-chat'

        const messages = [...history.slice(-6), { role: 'user', content: [{ type: 'text', text }] }]
        let out = ''
        for await (const chunk of llm.stream({ provider, model, system: persona, messages, maxTokens: 300, temperature: 0.9 })) {
          if (chunk?.type === 'text-delta') out += chunk.text
          else if (chunk?.type === 'finish' && chunk.reason?.kind === 'error') {
            throw new Error(chunk.reason.failure?.message || '模型断了')
          }
        }
        out = out.trim()
        if (!out) throw new Error('没有回话')

        history.push(
          { role: 'user', content: [{ type: 'text', text }] },
          { role: 'assistant', content: [{ type: 'text', text: out }], source: { kind: 'model', provider, model } },
        )
        while (history.length > 8) history.shift()

        sendJson(res, { ok: true, reply: out })
      } catch (error) {
        sendJson(res, { ok: false, error: String(error?.message ?? error) })
      }
    },
  }), 'ivan-pet-desktop: 对话接口')
}
