# TrackPal

macOS 選單列工具，讓觸控板支援**單指邊緣捲動**與**中鍵點擊**功能。

## 功能特色

- **單指垂直捲動** - 在觸控板左側或右側邊緣單指滑動即可上下捲動
- **單指水平捲動** - 在觸控板上方或下方邊緣單指滑動即可左右捲動
- **中鍵點擊** - 點擊觸控板中央區域觸發滑鼠中鍵
- **自然捲動** - 遵循 macOS 自然捲動方向
- **慣性捲動** - 滑動後自動減速的平滑捲動體驗
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
| 水平區域高度 | 水平捲動區域高度 | 20% |
| 捲動靈敏度 | 捲動速度倍率 | 3.0x |

## 技術資訊

- **語言**: Swift 6
- **框架**: SwiftUI、MultitouchSupport (Private Framework)
- **架構**: 選單列應用程式 (LSUIElement)

## 建置

```bash
# Debug 建置
xcodebuild -project TrackPal.xcodeproj -scheme TrackPal -configuration Debug build

# Release 建置
xcodebuild -project TrackPal.xcodeproj -scheme TrackPal -configuration Release build

# 部署到系統應用程式
cp -R ~/Library/Developer/Xcode/DerivedData/TrackPal-*/Build/Products/Release/TrackPal.app /Applications/
```

## 授權

MIT License

## 作者

Jason Chien
