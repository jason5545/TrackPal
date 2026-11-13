# TrackPal

macOS 選單列工具，給只能用一根手指操作觸控板的人：在觸控板邊緣滑動就能捲動，用力按就能送出中鍵、右鍵或系統動作，不需要任何多指手勢。

## 功能

### 捲動

- **單指垂直捲動**：在左側或右側邊緣上下滑（可選左、右或兩側）。
- **單指水平捲動**：在下方或上方的長條左右滑。
- **自然捲動方向**：跟 macOS 的兩指捲動一致。
- **慣性**：放開時還在滑，內容會繼續滑行一小段再停。
- **加速曲線**：線性、二次、三次、緩動。

### 用力按（Force Click）

- **中鍵**：在觸控板上緣（水平長條設在上方時是下緣）中間用力按。
- **角落動作**：四個角落各自可以設成右鍵、Mission Control、應用程式視窗、顯示桌面、啟動台、通知中心。

這些動作都要有壓力訊號才觸發，輕點一下不會誤觸；沒觸發時，原本的點擊照常送給 App。

### 分辨「要捲動」還是「要移游標」

邊緣區同時也是游標會經過的地方，所以每次接觸都先判斷意圖：

- **垂直邊緣與角落**：看累積的位移方向與連貫程度，至少兩筆有意義的位移才決定；單一幀的跳動不算。
- **水平長條**：游標優先。判斷期間游標照常移動，確定是一段留在長條內的橫向直線滑動才開始捲，並把游標放回落指時的位置。往觸控板內側走、離開長條、游移太久，都交回游標。
- **觸控過濾**：太輕的接觸（手指懸著）與太大的接觸（手掌、手腕）不算。
- **多指**：放下第二根手指就取消，交給系統手勢；全部放開之後才重新開始。

## 系統需求

- macOS 14.0 以上
- 有 Force Touch 的觸控板（沒有的話捲動照常可用，用力按的動作不能用）
- **輔助功能權限**

## 安裝

1. 把 `TrackPal.app` 放到 `/Applications`。
2. 啟動後依提示到「系統設定 → 隱私權與安全性 → 輔助功能」允許 TrackPal。

權限跟 App 的路徑綁在一起，換位置要重新授權。

## 設定

點選單列的圖示開啟面板，右上角的齒輪進設定頁。

| 設定 | 說明 | 預設值 | 範圍 |
|------|------|--------|------|
| 啟用區域捲動 | 總開關 | 開 | |
| 開機時自動啟動 | 登入後自動執行 | 開 | |
| 上下捲動 | 垂直捲動用哪一側 | 右側 | 左側／右側／雙側 |
| 水平捲動 | 水平長條在哪一邊 | 下方 | 下方／上方 |
| 邊緣寬度 | 垂直邊緣佔觸控板寬度 | 15% | 5–30% |
| 水平高度 | 水平長條佔觸控板高度 | 30% | 10–40% |
| 捲動靈敏度 | 位移換算成捲動量的倍率 | 3.0x | 1.0–10.0x |
| 加速曲線 | 位移到捲動量的曲線 | 線性 | 線性／二次／三次／緩動 |
| 啟用用力按壓中鍵 | 中鍵區用力按送出中鍵 | 開 | |
| 啟用用力按壓角落 | 角落的壓力動作 | 關 | |
| 角落區域大小 | 角落佔觸控板的比例 | 15% | 5–25% |
| 四個角落的動作 | 各自的壓力動作 | 右下角是右鍵，其餘無 | |

輕觸與大面積過濾預設開啟，門檻沒有放在介面上，要改用 `defaults write com.jasonchien.TrackPal <key> <值>`：
`filterLightTouches`、`filterLargeTouches`、`lightTouchDensityThreshold`（0.02）、`largeTouchMajorAxisThreshold`（15）、`largeTouchMinorAxisThreshold`（12）。

## 架構

```
TrackPal/                     App：選單列介面、裝置註冊
├── Sources/App/              進入點、AppRuntime（把各元件接起來）、在地化
├── Sources/Multitouch/       MultitouchSupport（私有 framework）的 callback
├── Sources/Views/            SwiftUI 介面
└── Resources/

TrackPalKit/                  Swift package
├── Sources/TrackPalCore/     純邏輯，不碰系統 API
│   ├── Engine/               手勢狀態機（ZoneScrollEngine）
│   ├── Gates/                各種意圖判斷
│   ├── Input/                裝置仲裁、callback 排序、壓力樣本緩衝
│   ├── Output/               慣性模型、捲動數值換算
│   └── Replay/               軌跡檔格式、重播、隨機情境產生器
├── Sources/TrackPalSystem/   macOS 整合：合成 CGEvent、event tap、
│                             display link、日誌、軌跡檔、設定儲存
├── Sources/trackpal-replay/  用實機軌跡重算的命令列工具
└── Tests/
```

狀態機不直接送事件、不讀時鐘、不寫檔，全部經過 `ZoneScrollEffects` 介面。App 接上真正的實作，測試與重算工具接上只記錄的實作，所以整條手勢流程（從觸控幀到送出的捲動、點擊）可以離線重播，同一段輸入一定得到同一串輸出。

用到的系統介面：

- **MultitouchSupport.framework**（私有）：原始觸控幀與壓力。
- **CGEventTap**：區域捲動期間擋掉系統自己的捲動與游標移動；攔下可能要改成壓力動作的原生點擊。
- **CADisplayLink**：慣性。

## 開發

```bash
# 測試（判斷邏輯與系統整合層，幾秒跑完，不用開 App）
swift test --package-path TrackPalKit

# 建置 App
xcodebuild -project TrackPal.xcodeproj -scheme TrackPal -configuration Release build
```

`xcodebuild … test` 也會跑同一批測試。

### 日誌與軌跡

- `~/Library/Logs/TrackPal.log`：每次接觸一筆總結，加上判斷過程的關鍵訊息。16 MB 輪替一次，保留上一份。
- `~/Library/Logs/TrackPal.traces.jsonl`：從捲動區、角落、中鍵區起步的接觸逐幀軌跡，一次接觸一行。只有觸控板上的座標與接觸面積，沒有游標位置、視窗或按鍵。8 MB 輪替一次。

### 改門檻之前先重算

```bash
cd TrackPalKit

# 水平長條：當時的結果 → 用目前規則重算的結果
swift run -c release trackpal-replay --summary

# 帶門檻試算
swift run -c release trackpal-replay D=0.04 slope=0.3 --summary

# 整個狀態機重播所有區域
swift run -c release trackpal-replay engine --summary

swift run -c release trackpal-replay --help
```

重算用的是 App 裡跑的同一份程式碼。

## 授權

MIT License

## 作者

Jason Chien
