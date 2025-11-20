//
//  AnchoredAnimationManager.swift
//
//  Created by Alisa Mylnikova on 23.10.2024.
//

import SwiftUI
import Combine

/// this manager stores states for all the paired growing/shrinking animations
@MainActor
class AnchoredAnimationManager: ObservableObject {
    static let shared = AnchoredAnimationManager()

    enum GrowingViewState {
        case hidden, growing, displayed, shrinking
    }

    struct AnimationItem: Equatable {
        var id: String
        var buttonFrame: IntRect
        var state: GrowingViewState

        static func == (lhs: AnimationItem, rhs: AnimationItem) -> Bool {
            lhs.id == rhs.id
            && lhs.buttonFrame == rhs.buttonFrame
            && lhs.state == rhs.state
        }
    }

    @Published var animations: [AnimationItem] = []

    private var statePublishers: [String: CurrentValueSubject<AnimationItem?, Never>] = [:]
    private var framePublishers: [String: CurrentValueSubject<AnimationItem?, Never>] = [:]
    private var cancellables = Set<AnyCancellable>()

    static subscript(id: String) -> AnimationItem? {
        shared.animations.first { $0.id == id }
    }

    func changeStateForAnimation(for id: String, state: GrowingViewState) {
        if let index = animations.firstIndex(where: { $0.id == id }) {
            animations[index].state = state
        }
    }

   func updateFrame(for id: String, frame: CGRect) {
        if let index = animations.firstIndex(where: { $0.id == id }) {
            animations[index].buttonFrame = frame.toIntRect()
        } else {
            animations.append(AnimationItem(id: id, buttonFrame: frame.toIntRect(), state: .hidden))
        }
    }

    func statePublisher(for id: String) -> CurrentValueSubject<AnimationItem?, Never> {
        if let publisher = statePublishers[id] {
            return publisher
        }

        // Track the last emitted value for comparison
        var lastValue: AnimationItem? = nil

        // Create a CurrentValueSubject to hold the current value
        let subject = CurrentValueSubject<AnimationItem?, Never>(nil)

        // Generate the publisher and handle state changes
        $animations
            .map { animations in
                animations.first { $0.id == id }
            }
            .compactMap { $0 }
            .filter { newItem in
                if let last = lastValue {
                    // Only emit if the item has changed from the last value
                    if last.state != newItem.state {
                        lastValue = newItem // Update the last value
                        return true // Emit if there's a change
                    } else {
                        return false // Don't emit if no change
                    }
                } else {
                    lastValue = newItem // Set initial value
                    return true // Emit the first time
                }
            }
            .sink { newItem in
                // Emit the value to the CurrentValueSubject
                subject.send(newItem)
            }
            .store(in: &cancellables)

        statePublishers[id] = subject
        return subject
    }

    func framePublisher(for id: String) -> CurrentValueSubject<AnimationItem?, Never> {
        if let publisher = framePublishers[id] {
            return publisher
        }

        // Track the last emitted value for comparison
        var lastValue: AnimationItem? = nil

        // Create a CurrentValueSubject to hold the current value
        let subject = CurrentValueSubject<AnimationItem?, Never>(nil)

        // Generate the publisher and handle state changes
        $animations
            .map { animations in
                animations.first { $0.id == id }
            }
            .compactMap { $0 }
            .filter { newItem in
                if let last = lastValue {
                    // Only emit if the item has changed from the last value
                    if last.buttonFrame != newItem.buttonFrame {
                        lastValue = newItem // Update the last value
                        return true // Emit if there's a change
                    } else {
                        return false // Don't emit if no change
                    }
                } else {
                    lastValue = newItem // Set initial value
                    return true // Emit the first time
                }
            }
            .sink { newItem in
                // Emit the value to the CurrentValueSubject
                subject.send(newItem)
            }
            .store(in: &cancellables)

        framePublishers[id] = subject
        return subject
    }
}

struct TriggerButton<V>: ViewModifier where V: View {
    @State var id: String
    var params: PopupParameters
    @ViewBuilder var contentBuilder: () -> V

    @State private var cancellable: AnyCancellable?

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    Color.clear
                        .preference(key: ButtonFramePreferenceKey.self, value: ButtonFrameInfo(id: id, frame: geo.frame(in: .global)))
                }
            }
            .onPreferenceChange(ButtonFramePreferenceKey.self) { value in
                DispatchQueue.main.async {
                    if id == value.id {
                        AnchoredAnimationManager.shared.updateFrame(for: value.id, frame: value.frame)
                    }
                }
            }
            .simultaneousGesture(
                TapGesture().onEnded { gesture in
                    // trigger displaying animation
                    hideKeyboard()
                    AnchoredAnimationManager.shared.changeStateForAnimation(for: id, state: .growing)
                }
            )
            .onReceive(AnchoredAnimationManager.shared.statePublisher(for: id)) { animation in
                if animation?.state == .growing {
                    WindowManager.openNewWindow(id: id, closeOnTapOutside: params.closeOnTapOutside, isPassthrough: params.isPassthrough) {
                        ZStack {
                            AnimatedBackgroundView(id: $id, background: params.background)
                                .simultaneousGesture(
                                    TapGesture().onEnded {
                                        if params.closeOnTapOutside {
                                            // trigger hiding animation
                                            AnchoredAnimationManager.shared.changeStateForAnimation(for: id, state: .shrinking)
                                        }
                                    }
                                )
                            AnchoredAnimationView(id: id, params: params, contentBuilder: contentBuilder)
                        }
                    }
                } else if animation?.state == .hidden {
                    WindowManager.closeWindow(id: id)
                }
            }
    }
}

@MainActor
fileprivate struct AnchoredAnimationView<V>: View where V: View {
    var id: String
    var params: PopupParameters
    var contentBuilder: () -> V

    @State private var animatableOpacity: CGFloat = 0
    @State private var animatableScale: CGSize = .zero
    @State private var animatableOffset: CGSize = .zero

    @State private var triggerButtonFrame: IntRect = .zero
    @State private var contentSize: IntSize = .zero

    // @State private var semaphore = DispatchSemaphore(value: 1)
    // 1. 替换 Semaphore 为一个简单的布尔状态标志
    @State private var isAnimating: Bool = false

    var body: some View {
        VStack {
            contentBuilder()
                .overlay(GeometryReader { geo in
                    Color.clear.onAppear {
                        DispatchQueue.main.async {
                            contentSize = geo.size.toIntSize()
                            if let animation = AnchoredAnimationManager.shared.animations.first(where: { $0.id == id }) {

                                // 初始状态设置，在 onAppear 时就绪
                                if animation.state == .growing {
                                    setHiddenState()
                                }

                                setupAndLaunchAnimation(animation)
                            }
                        }
                    }
                })
                .scaleEffect(animatableScale)
                .offset(animatableOffset)
                .position(x: triggerButtonFrame.floatMidX, y: triggerButtonFrame.floatMidY)
                .opacity(animatableOpacity)
                .ignoresSafeArea()
                .simultaneousGesture(
                    TapGesture().onEnded { gesture in
                        if params.closeOnTap {
                            // trigger hiding animation
                            AnchoredAnimationManager.shared.changeStateForAnimation(for: id, state: .shrinking)
                        }
                    }
                )
        }
        .onReceive(AnchoredAnimationManager.shared.framePublisher(for: id)) { animation in
            if let animation, triggerButtonFrame == .zero {
                triggerButtonFrame = animation.buttonFrame
            }
        }
        .onReceive(AnchoredAnimationManager.shared.statePublisher(for: id)) { animation in
            if let animation {
                setupAndLaunchAnimation(animation)
            }
        }
    }

    private func setupAndLaunchAnimation(_ animation: AnchoredAnimationManager.AnimationItem) {
        if contentSize == .zero || triggerButtonFrame == .zero { return }

        // 2. 使用状态标志作为守卫，防止动画进行时被重入
        if isAnimating {
            return
        }

        // semaphore.wait()
        let currentState = animation.state
        let isVisuallyHidden = animatableOpacity == 0


         if currentState == .growing && isVisuallyHidden {
            // 只有在视图当前是隐藏状态时才执行“ growing”动画
            performGrowingAnimation()
        } else if currentState == .shrinking && !isVisuallyHidden {
            // 只有在视图当前是可见状态时才执行“shrinking”动画
            performShrinkingAnimation()
        }

        
    }


    private func performGrowingAnimation() {
        // 3. 在动画开始前锁定
        isAnimating = true
        setHiddenState() // 确保从正确的隐藏状态开始

        if #available(iOS 17.0, *) {
            withAnimation(params.animation) {
                setDisplayedState()
            } completion: {
                AnchoredAnimationManager.shared.changeStateForAnimation(for: id, state: .displayed)
                // 4. 在动画完成后解锁
                isAnimating = false
            }
        } else {
            withAnimation(params.animation) {
                setDisplayedState()
            }
            // 使用在 PopupParameters 中定义的动画时长
            DispatchQueue.main.asyncAfter(deadline: .now() + params.animationDuration) {
                AnchoredAnimationManager.shared.changeStateForAnimation(for: id, state: .displayed)
                // 4. 在动画完成后解锁
                isAnimating = false
            }
        }
    }


    private func performShrinkingAnimation() {
        // 3. 在动画开始前锁定
        isAnimating = true

        if #available(iOS 17.0, *) {
            withAnimation(params.animation) {
                setHiddenState()
            } completion: {
                params.onDisappear?()
                AnchoredAnimationManager.shared.changeStateForAnimation(for: id, state: .hidden)
                // 4. 在动画完成后解锁
                isAnimating = false
            }
        } else {
            withAnimation(params.animation) {
                setHiddenState()
            }
            // 使用在 PopupParameters 中定义的动画时长
            DispatchQueue.main.asyncAfter(deadline: .now() + params.animationDuration) {
                params.onDisappear?()
                AnchoredAnimationManager.shared.changeStateForAnimation(for: id, state: .hidden)
                // 4. 在动画完成后解锁
                isAnimating = false
            }
        }
    }

    private func setHiddenState() {
        animatableOffset = .zero
        animatableScale = calculateHiddenScale()
        animatableOpacity = 0
    }

    private func setDisplayedState() {
        animatableOffset = calculateDisplayedOffset()
        animatableScale = CGSize(width: 1, height: 1)
        animatableOpacity = 1
    }

    /// start with popup matching trigger's position and size
    private func calculateHiddenScale() -> CGSize {
        let tw = triggerButtonFrame.floatWidth
        let th = triggerButtonFrame.floatHeight
        let pw = contentSize.floatWidth
        let ph = contentSize.floatHeight
        return CGSize(width: tw/pw, height: th/ph)
    }

    /// starting position is center of the trigger
    private func calculateDisplayedOffset() -> CGSize {
        let cw = contentSize.floatWidth
        let ch = contentSize.floatHeight

        switch params.position {
        case .anchorRelative(let p):
            let tw = triggerButtonFrame.floatWidth
            let th = triggerButtonFrame.floatHeight

            // difference between centers
            let w = cw/2 - tw/2
            let h = ch/2 - th/2

            // normalization: (0, 1) -> (1, -1)
            let px = -2 * p.x + 1
            let py = -2 * p.y + 1

            // the content view center is currently same as anchor view
            // +/- the difference between centers
            return CGSize(width: w * px, height: h * py)

        case .screenRelative(let p):
            let tx = triggerButtonFrame.floatMidX
            let ty = triggerButtonFrame.floatMidY
            let sw = UIScreen.main.bounds.width
            let sh = UIScreen.main.bounds.height

            // normalization: (0, 1) -> (1, -1)
            let px = -2 * p.x + 1
            let py = -2 * p.y + 1

            // the content view center is currently same as anchor view
            // -tx: put middle of popup into (0,0)
            // sw * p.x: put middle of popup into required unit point of screen
            // cw/2 * px: align required unit point of popup with the screen
            return CGSize(width: -tx + sw * p.x + cw/2 * px, height: -ty + sh * p.y + ch/2 * py)
        }
    }
}