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
const CRED_PATH = join(homedir(), '.dsh', '.credentials.yaml')

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
  // 这一轮有没有真干过活：不能靠 current.state 判断——assistant 开始吐字后状态会落到
  // speaking（优先级低于 coding），轮到 idle 时看 current.state 就以为"没忙过"，气泡永远不弹。
  let busy = false

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
          busy = true
          set('thinking', { sessionId })
        } else if (status === 'idle') {
          if (busy) {
            busy = false
            set('done', { sessionId, force: true, ttlMs: TTL.done })
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

  const relayUsage = async (key) => {
    const res = await fetch(`${RELAY_GATEWAY}/api/usage/token`, {
      headers: { authorization: `Bearer ${key}` },
      signal: AbortSignal.timeout(8000),
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const json = await res.json()
    return json?.data ?? null
  }

  const deepseekUsage = async (origin, token) => {
    const res = await fetch(`${origin}/api/v0/users/get_user_summary`, {
      headers: { 'x-dsh-auth-token': token },
      signal: AbortSignal.timeout(8000),
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const json = await res.json()
    return json?.data?.biz_data ?? null
  }

  const num = (v) => {
    const n = Number.parseFloat(String(v ?? '0'))
    return Number.isFinite(n) ? n : 0
  }

  const collectBalance = async () => {
    const out = { ok: true, at: Date.now() }
    let raw = ''
    try {
      raw = readFileSync(CRED_PATH, 'utf8')
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

    // 中转站：每个 key 查一次已用，再求和
    const channels = []
    let totalUsed = 0
    let unlimited = true
    await Promise.all(
      RELAY_KEYS.map(async ([env, label]) => {
        const key = creds[env]
        try {
          const data = await relayUsage(key)
          const used = num(data?.total_used) / RELAY_QUOTA_PER_USD
          const granted = num(data?.total_granted) / RELAY_QUOTA_PER_USD
          const isUnlimited = data?.unlimited_quota === true
          if (!isUnlimited) unlimited = false
          totalUsed += used
          channels.push({ label, ok: true, used, granted, unlimited: isUnlimited })
        } catch (error) {
          channels.push({ label, ok: false, error: String(error?.message ?? error) })
        }
      }),
    )
    channels.sort((a, b) => RELAY_KEYS.findIndex((k) => k[1] === a.label) - RELAY_KEYS.findIndex((k) => k[1] === b.label))
    out.relay = { ok: channels.some((c) => c.ok), totalUsed, unlimited, channels }
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
}