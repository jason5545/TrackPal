import CoreGraphics
import Foundation

/// 系統原生雙指捲動的手感，量出來的。
///
/// 2026-11-13 在 Jason 的 MacBook 上錄了 55 次原生雙指捲動（雙指的觸控幀加上
/// 系統送出的捲動事件，其中 38 次帶慣性；`NativeScrollRecorder`），從裡面擬合
/// 出兩條曲線。速度的單位都是「每秒滑過幾個觸控板高」；水平方向先乘上寬高比
/// 換成同樣的實體尺度。靈敏度 1.0 就是原生的量。
///
/// 兩條曲線都是「增益隨速度線性增加」：系統的捲動加速（IOHIDFamily 的
/// `IOHIDParametricAcceleration`，登錄裡的 `HIDScrollAccelCurves`）在一般速度
/// 範圍內就是這個形式，所以用它來外插錄不到的快速區。
///
/// - 接觸中：每滑過一個觸控板高捲動 `500 + 119·v` 個像素。實測 0.35–0.5
///   是 550、0.5–0.75 是 597、0.75–1.0 是 616、1.0–1.5 是 649。
/// - 放開時：手指速度 0.35 以上就有慣性（38 次裡最低是 0.35；沒有慣性的
///   17 次幾乎都在 0.5 以下）。起始速度 `v × (650 + 500·v)` px/s。實測的
///   中位數：0.44 → 360、0.62 → 480、0.78 → 780、1.05 → 1680（只有 3 筆）；
///   原生的值是每筆整數像素，所以是 120 px/s 一階。
/// - 慣性之後指數衰減。原生的總距離是峰值速度的 0.239 秒（中位數），收在
///   每筆 1–2 px；時間常數 0.27 秒、低於 120 px/s 停，總距離跟實測對得上
///   （840 px/s → 194 px，原生 184–209；2280 → 583，原生 544）。
///
/// **快速區是外插的。** 錄到的雙指捲動放開速度最快只有 1.1 左右，而單指在
/// 邊緣滑動放開時的中位數是 1.46。放開得很快時慣性太強或太弱，調的是
/// `momentumSpeed` 裡的二次項。換了機器、或系統的捲動速度設定改了，要重錄
/// 再擬合；`trackpal-replay native` 會把錄到的軌跡丟進狀態機跟原生對帳。
public enum NativeScrollCurve {
    /// 沒有速度資訊時用的手指速度（例如啟動那一刻）。
    public static let nominalSpeed: CGFloat = 0.5

    /// 接觸中的增益：手指每滑過一個觸控板高，捲動幾個像素。
    public static func contactGain(atSpeed speed: CGFloat) -> CGFloat {
        let magnitude = speed.isFinite ? min(abs(speed), 4.0) : nominalSpeed
        return 500 + 119 * magnitude
    }

    /// 放開時手指速度低於這個值就沒有慣性。
    public static let momentumMinimumLiftSpeed: CGFloat = 0.35

    /// 慣性的起始速度（px/s）；放開得太慢時是 0。
    public static func momentumSpeed(atLiftSpeed speed: CGFloat) -> CGFloat {
        let magnitude = abs(speed)
        guard magnitude.isFinite, magnitude >= momentumMinimumLiftSpeed else {
            return 0
        }
        let clamped = min(magnitude, 6.0)
        return clamped * (650 + 500 * clamped)
    }

    /// 慣性速度的衰減時間常數（秒）。
    public static let momentumTimeConstant: Double = 0.27

    /// 慣性慢到這個速度（px/s）就停。
    public static let momentumStopSpeed: CGFloat = 120
}
