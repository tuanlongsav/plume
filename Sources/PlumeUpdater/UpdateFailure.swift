import Foundation
import PlumeCore

public enum UpdateFailure: Error, Equatable {
    case checkFailed
    case rateLimited
    case downloadFailed
    case invalidPackage
    case needsNewerSystem(String)
    case installFailed
    case ineligible(String)

    public var title: String {
        switch self {
        case .checkFailed, .rateLimited:
            return L.t("Không kiểm tra được cập nhật", "Couldn't check for updates")
        case .downloadFailed:
            return L.t("Không tải được bản cập nhật", "Couldn't download the update")
        case .invalidPackage:
            return L.t("Gói cập nhật không hợp lệ", "The update package failed verification")
        case .needsNewerSystem:
            return L.t("Cần macOS mới hơn", "A newer macOS is required")
        case .installFailed, .ineligible:
            return L.t("Không thể tự cập nhật", "Plume can't update itself")
        }
    }

    public var detail: String {
        switch self {
        case .checkFailed, .downloadFailed:
            return L.t("Kiểm tra kết nối mạng rồi thử lại.", "Check your connection and try again.")
        case .rateLimited:
            return L.t("Máy chủ cập nhật đang giới hạn số lần hỏi từ mạng này. Thử lại sau khoảng một giờ.",
                       "The update server is limiting requests from this network. Try again in about an hour.")
        case .invalidPackage:
            return L.t("Plume đã huỷ cài đặt và giữ nguyên bản hiện tại.",
                       "Plume cancelled the install and kept the current version.")
        case .needsNewerSystem(let v):
            return L.t("Bản mới cần macOS \(v) trở lên.", "The new version needs macOS \(v) or later.")
        case .installFailed:
            return L.t("Không thay được ứng dụng. Bản hiện tại vẫn nguyên vẹn; hãy tải bản mới về cài tay.",
                       "The app could not be replaced. The current version is intact; download the new one and install it by hand.")
        case .ineligible(let detail):
            return detail
        }
    }
}
