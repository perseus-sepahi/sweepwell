// Lists Sweepwell's windows: id layer x y width height onscreen. Used by the capture scripts.
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String) == "Sweepwell" {
    let b = w[kCGWindowBounds as String] as! [String: Any]
    let on = (w[kCGWindowIsOnscreen as String] as? Bool) == true ? 1 : 0
    print(w[kCGWindowNumber as String]!, w[kCGWindowLayer as String]!, b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!, on)
}
