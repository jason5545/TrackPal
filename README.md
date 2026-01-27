# TrackPal

macOS 選單列工具，讓觸控板支援**單指邊緣捲動**、**中鍵點擊**與**智慧觸控過濾**功能。

## 功能特色

### 核心捲動

- **單指垂直捲動** - 在觸控板左側或右側邊緣單指滑動即可上下捲動
- **單指水平捲動** - 在觸控板上方或下方邊緣單指滑動即可左右捲動
- **中鍵點擊** - 點擊觸控板中央區域觸發滑鼠中鍵
- **自然捲動** - 遵循 macOS 自然捲動方向

### 智慧捲動引擎

- **意圖預測** - 觸控落在區域邊界時，系統分析前 3 幀移動方向自動判斷水平或垂直捲動
- **速度自適應慣性** - 輕滑快速停止，用力滑動慣性持續更久
- **子像素累加器** - 避免 Int32 截斷造成的微小移動死區
- **寬高比補償** - 自動補償觸控板 ~1.6:1 寬高比，水平捲動與垂直一致

### 觸控過濾

- **輕觸過濾** - 過濾手指懸浮或輕觸的誤觸（密度閾值）
- **大面積過濾** - 過濾手掌或手腕的誤觸（橢圓軸閾值）
- **多指手勢處理** - 單指↔多指轉換時自動取消捲動，避免與系統手勢衝突
- **CGEventTap 攔截** - 區域捲動期間抑制系統重複捲動事件

### 其他功能

- **角落觸發** - 點擊觸控板四個角落觸發系統動作（Mission Control、顯示桌面等）
- **加速曲線** - 可選擇線性、二次、三次或緩動曲線調整捲動手感
- **開機自動啟動** - 支援登入時自動啟動

## 系統需求

- macOS 14.0 或更新版本
- 需要**輔助功能權限**

## 安裝

1. 下載 `TrackPal.app`
2. 將應用程式移動到 `/Applications` 資料夾
3. 啟動 TrackPal
4. 依提示授予輔助功能權限：
   - 系統設定 → 隱私權與安全性 → 輔助功能 → 允許 TrackPal

## 使用方式

啟動後，TrackPal 會在選單列顯示圖示。點擊圖示可開啟設定面板：

### 設定選項

| 設定 | 說明 | 預設值 |
|------|------|--------|
| 啟用區域捲動 | 開啟/關閉主要功能 | 開啟 |
| 開機時自動啟動 | 登入時自動啟動 | 開啟 |
| 上下捲動區域 | 垂直捲動使用的邊緣 | 右側 |
| 水平捲動位置 | 水平捲動區域位置 | 下方 |
| 啟用中鍵點擊 | 點擊中央觸發中鍵 | 開啟 |
| 邊緣寬度 | 捲動區域佔觸控板比例 | 15% |
| 水平區域高度 | 水平捲動區域高度 | 30% |
| 捲動靈敏度 | 捲動速度倍率 | 3.0x |
| 捲動加速曲線 | 捲動加速方式 | 線性 |
| 啟用角落觸發 | 開啟/關閉角落觸發 | 關閉 |
| 角落區域大小 | 角落觸發區域大小 | 15% |
| 過濾輕觸 | 過濾懸浮/輕觸的誤觸 | 開啟 |
| 過濾大面積觸控 | 過濾手掌/手腕的誤觸 | 開啟 |

### 慣性行為

| 滑動力道 | 行為 |
|----------|------|
| 無/極輕（速度 < 50） | 跟隨手指，抬起即停 |
| 輕滑（50-120） | 短暫慣性，快速停止 |
| 正常滑動（120-250） | 標準慣性 |
| 用力滑動（> 250） | 完整慣性，持續較久 |

### 角落觸發動作

啟用角落觸發後，可為四個角落分別設定動作：

| 動作 | 說明 |
|------|------|
| 無動作 | 不執行任何操作 |
| Mission Control | 顯示所有視窗與桌面 |
| 應用程式視窗 | 顯示目前應用程式的所有視窗 |
| 顯示桌面 | 隱藏所有視窗顯示桌面 |
| 啟動台 | 開啟 Launchpad |
| 通知中心 | 開啟通知中心 |

### 加速曲線類型

| 曲線 | 說明 |
|------|------|
| 線性 | 1:1 直接對應，適合精確控制 |
| 二次 | 小幅滑動較緩，大幅滑動加速 |
| 三次 | 更強的加速效果 |
| 緩動 | 平滑過渡，適合一般使用 |

## 技術架構

```
TrackPal/Sources/
├── TrackPalApp.swift             # App 入口、AppDelegate、Settings 管理
├── TrackpadZoneScroller.swift    # 核心：區域偵測、觸控過濾、意圖預測、事件攔截
├── InertiaScroller.swift         # CVDisplayLink 慣性引擎（速度自適應摩擦力）
├── LogManager.swift              # 檔案日誌系統 (~/Library/Logs/TrackPal.log)
├── MultitouchSupport.h           # Private framework 宣告
├── TrackPal-Bridging-Header.h
└── Views/
    ├── MenuBarPopupView.swift    # 設定面板 UI
    ├── DesignSystem/
    │   ├── DesignTokens.swift    # 色彩、字型、間距常數
    │   └── VisualEffectBackground.swift
    └── Components/
        ├── TrackpadDiagramView.swift     # 觸控板區域視覺化
        └── SettingsSliderRow.swift       # 滑桿元件
```

### 關鍵技術

- **MultitouchSupport.framework** - Apple 私有框架，取得原始觸控板資料
- **CGEventTap** - 系統層級事件攔截，避免捲動事件衝突
- **CVDisplayLink** - 畫面同步的慣性捲動更新
- **os_unfair_lock** - 執行緒安全的跨 callback 狀態同步

## 建置

```bash
# Debug 建置
xcodebuild -project TrackPal.xcodeproj -scheme TrackPal -configuration Debug build

# Release 建置
xcodebuild -project TrackPal.xcodeproj -scheme TrackPal -configuration Release build

# 部署到系統應用程式
cp -R ~/Library/Developer/Xcode/DerivedData/TrackPal-*/Build/Products/Release/TrackPal.app /Applications/
```

## 診斷日誌

TrackPal 會寫入日誌到 `~/Library/Logs/TrackPal.log`，可用於除錯：

```bash
# 即時查看日誌
tail -f ~/Library/Logs/TrackPal.log
```

## 授權

MIT License

## 作者

Jason Chien
