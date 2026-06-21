@echo off
chcp 65001 >nul
setlocal

echo  ╔══════════════════════════════════════════╗
echo  ║     CrossLink Agent Launcher v2.0       ║
echo  ╚══════════════════════════════════════════╝
echo.

REM ═══════════════════════════════════════════
REM  配置区 — 按需修改
REM ═══════════════════════════════════════════

REM 中继服务器地址（留空=LAN直连模式）
if "%RELAY_ADDR%"=="" set RELAY_ADDR=ws://crosslink.cyou:18080/agent

REM Agent 标识（默认用计算机名）
if "%PEER_ID%"=="" set PEER_ID=agent-%COMPUTERNAME%

REM Claude 会话工作目录（真实路径，自动转换）
if "%CLAUDE_PROJECT_DIR%"=="" set CLAUDE_PROJECT_DIR=C:\mySpace\ClaudeProject

REM DeepSeek API Key（可选，不设置则仅Claude可用）
REM set DEEPSEEK_API_KEY=sk-xxx

REM Agent 可见性（public=手机端可发现，private=仅自己可见）
if "%AGENT_VISIBILITY%"=="" set AGENT_VISIBILITY=public

REM ═══════════════════════════════════════════
echo  Relay:        %RELAY_ADDR%
echo  Peer ID:      %PEER_ID%
echo  Claude 项目:  %CLAUDE_PROJECT_DIR%
echo  可见性:       %AGENT_VISIBILITY%
echo  ═══════════════════════════════════════════
echo.
echo  启动中...
echo.

REM Run agent
ollama-agent.exe
pause
