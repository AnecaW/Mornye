import Flutter
import UIKit

/// In-place UIKit controls for the existing Flutter screens and navigation.
final class IosSystemViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        IosSystemView(frame: frame, id: viewId, args: args as? [String: Any] ?? [:], messenger: messenger)
    }
}

private final class IosSystemView: NSObject, FlutterPlatformView, UITabBarDelegate {
    private let container: UIView
    private let channel: FlutterMethodChannel
    private let control: UIView
    private var tabSymbols: [String] = []

    init(frame: CGRect, id: Int64, args: [String: Any], messenger: FlutterBinaryMessenger) {
        container = UIView(frame: frame)
        channel = FlutterMethodChannel(name: "com.zarz.mornye/ios_system_view/\(id)", binaryMessenger: messenger)
        switch args["kind"] as? String {
        case "switch": control = UISwitch()
        case "segments": control = UISegmentedControl()
        case "tabs": control = UITabBar()
        case "menu": control = UIButton(type: .system)
        default: control = UIVisualEffectView()
        }
        super.init()
        control.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(control)
        if let toggle = control as? UISwitch {
            NSLayoutConstraint.activate([
                toggle.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                toggle.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
        } else {
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                control.topAnchor.constraint(equalTo: container.topAnchor),
                control.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        if let segments = control as? UISegmentedControl {
            segments.addTarget(self, action: #selector(segmentChanged(_:)), for: .valueChanged)
        }
        (control as? UITabBar)?.delegate = self
        configure(args)
        channel.setMethodCallHandler { [weak self] call, result in
            guard call.method == "configure", let values = call.arguments as? [String: Any] else {
                result(FlutterMethodNotImplemented)
                return
            }
            self?.configure(values)
            result(nil)
        }
    }

    deinit { channel.setMethodCallHandler(nil) }

    func view() -> UIView { container }

    private func configure(_ values: [String: Any]) {
        container.overrideUserInterfaceStyle = values["dark"] as? Bool == true ? .dark : .light
        container.semanticContentAttribute = values["rtl"] as? Bool == true ? .forceRightToLeft : .forceLeftToRight
        if let toggle = control as? UISwitch {
            toggle.setOn(values["value"] as? Bool ?? false, animated: false)
            toggle.isEnabled = values["enabled"] as? Bool ?? false
            toggle.accessibilityLabel = values["label"] as? String
        } else if let segments = control as? UISegmentedControl {
            let labels = values["labels"] as? [String] ?? []
            if labels != (0..<segments.numberOfSegments).map({ segments.titleForSegment(at: $0) ?? "" }) {
                segments.removeAllSegments()
                for (index, title) in labels.enumerated() {
                    segments.insertSegment(withTitle: title, at: index, animated: false)
                }
            }
            segments.selectedSegmentIndex = values["selected"] as? Int ?? UISegmentedControl.noSegment
        } else if let tabs = control as? UITabBar {
            let items = values["items"] as? [[String: Any]] ?? []
            let symbols = items.map { $0["symbol"] as? String ?? "" }
            if symbols != tabSymbols {
                tabs.items = symbols.enumerated().map { index, symbol in
                    UITabBarItem(title: nil, image: UIImage(systemName: symbol), tag: index)
                }
                tabSymbols = symbols
            }
            for (tab, item) in zip(tabs.items ?? [], items) {
                tab.title = item["label"] as? String
                let count = item["count"] as? Int ?? 0
                tab.badgeValue = count > 0 ? String(count) : nil
            }
            if let index = values["selected"] as? Int, let items = tabs.items, items.indices.contains(index) {
                tabs.selectedItem = items[index]
            }
        } else if let button = control as? UIButton {
            var configuration: UIButton.Configuration
            if #available(iOS 26.0, *) {
                configuration = values["glass"] as? Bool == true ? .glass() : .plain()
            } else {
                configuration = .plain()
            }
            configuration.image = UIImage(systemName: "ellipsis")
            configuration.baseForegroundColor = .label
            button.configuration = configuration
            button.accessibilityLabel = values["label"] as? String
            button.showsMenuAsPrimaryAction = true
            let items = values["items"] as? [[String: Any]] ?? []
            button.isEnabled = !items.isEmpty
            button.menu = UIMenu(children: items.map { item in
                UIAction(title: item["label"] as? String ?? "",
                    image: (item["symbol"] as? String).flatMap { UIImage(systemName: $0) },
                    attributes: item["destructive"] as? Bool == true ? .destructive : [],
                    state: item["selected"] as? Bool == true ? .on : .off) { [weak self] _ in
                        self?.channel.invokeMethod("changed", arguments: item["id"])
                    }
            })
        } else if let surface = control as? UIVisualEffectView {
            container.isUserInteractionEnabled = false
            let wantsGlass = values["glass"] as? Bool == true
            if #available(iOS 26.0, *), wantsGlass {
                let radius = (values["radius"] as? NSNumber)?.doubleValue ?? 0
                let top: UICornerRadius? = values["top"] as? Bool == true ? .fixed(radius) : nil
                let bottom: UICornerRadius? = values["bottom"] as? Bool == true ? .fixed(radius) : nil
                surface.cornerConfiguration = .corners(topLeftRadius: top, topRightRadius: top,
                    bottomLeftRadius: bottom, bottomRightRadius: bottom)
                let glass = UIGlassEffect(style: values["clear"] as? Bool == true ? .clear : .regular)
                if let tint = (values["tint"] as? NSNumber)?.uint32Value {
                    glass.tintColor = UIColor(
                        red: CGFloat((tint >> 16) & 255) / 255,
                        green: CGFloat((tint >> 8) & 255) / 255,
                        blue: CGFloat(tint & 255) / 255,
                        alpha: CGFloat(tint >> 24) / 255
                    )
                }
                surface.effect = glass
            } else {
                surface.effect = UIBlurEffect(style: .systemMaterial)
            }
        }
    }

    @objc private func toggleChanged(_ sender: UISwitch) {
        channel.invokeMethod("changed", arguments: sender.isOn)
    }

    @objc private func segmentChanged(_ sender: UISegmentedControl) {
        channel.invokeMethod("changed", arguments: sender.selectedSegmentIndex)
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        channel.invokeMethod("changed", arguments: item.tag)
    }
}
