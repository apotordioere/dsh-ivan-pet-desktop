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
export const inject = []

const HERE = fileURLToPath(new URL('.', import.meta.url))
const SCRIPT = join(HERE, 'pet', 'pet.ps1')
const DEFAULT_ASSETS = join(HERE, 'pet', 'assets')
const STATE_DIR = join(process.env.APPDATA || join(homedir(), 'AppData', 'Roaming'), 'ivan-pet-desktop')
const PID_FILE = join(STATE_DIR, 'pet.pid')

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
    const args = [
      '-NoProfile',
      '-STA',
      '-ExecutionPolicy', 'Bypass',
      '-WindowStyle', 'Hidden',
      '-File', SCRIPT,
      '-Assets', assets,
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
      log('桌宠窗口已关闭')
    }
  }, 'ivan-pet-desktop: 拉起桌面窗口')
}
