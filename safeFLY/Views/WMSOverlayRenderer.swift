//
//  WMSOverlayRenderer.swift
//  safeFLY
//
//  Adds a native MKOverlay to the SwiftUI Map's underlying MKMapView.
//  The overlay image moves perfectly with the map during panning.
//

import SwiftUI
import MapKit

class WMSImageOverlay: NSObject, MKOverlay {
    let payloadID: String
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    let imageURL: URL
    let opacity: Double
    var image: UIImage?

    init(payload: WMSRenderPayload) {
        self.payloadID = payload.id
        self.imageURL = payload.imageURL
        self.opacity = payload.opacity

        let region = MKCoordinateRegion(payload.region)
        self.coordinate = region.center

        let topLeft = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude + region.span.latitudeDelta / 2,
            longitude: region.center.longitude - region.span.longitudeDelta / 2
        ))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(
            latitude: region.center.latitude - region.span.latitudeDelta / 2,
            longitude: region.center.longitude + region.span.longitudeDelta / 2
        ))
        self.boundingMapRect = MKMapRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
        super.init()
    }
}

class WMSImageRenderer: MKOverlayRenderer {
    var overlayImage: UIImage?

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let image = overlayImage?.cgImage else { return }
        let rect = self.rect(for: overlay.boundingMapRect)

        context.saveGState()
        context.translateBy(x: rect.origin.x, y: rect.origin.y + rect.size.height)
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

class MapDelegateProxy: NSObject, MKMapViewDelegate {
    weak var originalDelegate: MKMapViewDelegate?
    var rendererProvider: ((MKOverlay) -> MKOverlayRenderer?)?

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let renderer = rendererProvider?(overlay) {
            return renderer
        }

        return originalDelegate?.mapView?(mapView, rendererFor: overlay) ?? MKOverlayRenderer(overlay: overlay)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) {
            return true
        }
        return originalDelegate?.responds(to: aSelector) ?? false
    }
    
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original = originalDelegate, original.responds(to: aSelector) {
            return original
        }
        return super.forwardingTarget(for: aSelector)
    }
}

struct WMSNativeOverlay: UIViewRepresentable {
    let payloads: [WMSRenderPayload]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WMSOverlayHostView {
        let view = WMSOverlayHostView()
        view.coordinator = context.coordinator
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: WMSOverlayHostView, context: Context) {
        let coordinator = context.coordinator
        guard payloads != coordinator.currentPayloads else {
            return
        }

        coordinator.currentPayloads = payloads
        coordinator.generation += 1
        coordinator.cancelDownloads()

        guard let mapView = uiView.findMKMapView() else {
            return
        }

        coordinator.installDelegateProxy(on: mapView)

        let existing = mapView.overlays.filter { $0 is WMSImageOverlay }
        if !existing.isEmpty {
            mapView.removeOverlays(existing)
        }

        let generation = coordinator.generation

        for payload in payloads {
            coordinator.downloadImage(payloadID: payload.id, url: payload.imageURL) { image in
                guard let image else { return }
                guard generation == coordinator.generation else { return }

                let overlay = WMSImageOverlay(payload: payload)
                overlay.image = image
                mapView.addOverlay(overlay, level: .aboveLabels)
            }
        }
    }

    class Coordinator: NSObject {
        var currentPayloads: [WMSRenderPayload] = []
        var generation = 0
        private var delegateProxy: MapDelegateProxy?
        private var downloadTasks: [String: URLSessionDataTask] = [:]

        func downloadImage(payloadID: String, url: URL, completion: @escaping (UIImage?) -> Void) {
            let task = URLSession.shared.dataTask(with: url) { data, _, _ in
                DispatchQueue.main.async {
                    self.downloadTasks[payloadID] = nil
                    if let data = data, let image = UIImage(data: data) {
                        completion(image)
                    } else {
                        completion(nil)
                    }
                }
            }
            downloadTasks[payloadID] = task
            task.resume()
        }

        func cancelDownloads() {
            for task in downloadTasks.values {
                task.cancel()
            }

            downloadTasks.removeAll()
        }

        func installDelegateProxy(on mapView: MKMapView) {
            if mapView.delegate is MapDelegateProxy {
                return
            }

            let proxy = MapDelegateProxy()
            proxy.originalDelegate = mapView.delegate
            proxy.rendererProvider = { overlay in
                if let wmsOverlay = overlay as? WMSImageOverlay {
                    let renderer = WMSImageRenderer(overlay: wmsOverlay)
                    renderer.alpha = CGFloat(wmsOverlay.opacity)
                    renderer.overlayImage = wmsOverlay.image
                    return renderer
                }
                return nil
            }

            self.delegateProxy = proxy
            mapView.delegate = proxy
        }
    }
}

class WMSOverlayHostView: UIView {
    weak var coordinator: WMSNativeOverlay.Coordinator?

    func findMKMapView() -> MKMapView? {
        var current: UIView? = self
        while let view = current {
            if let mapView = view as? MKMapView {
                return mapView
            }
            if let found = view.findSubview(ofType: MKMapView.self) {
                return found
            }
            current = view.superview
        }
        return nil
    }
}

extension MKCoordinateRegion {
    init(_ region: MapRegion) {
        self.init(
            center: region.center.clLocationCoordinate2D,
            span: MKCoordinateSpan(latitudeDelta: region.latitudeDelta, longitudeDelta: region.longitudeDelta)
        )
    }
}

extension UIView {
    func findSubview<T: UIView>(ofType type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T {
                return match
            }
            if let found = subview.findSubview(ofType: type) {
                return found
            }
        }
        return nil
    }
}
