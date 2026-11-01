import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    var body: some View {
        VStack(spacing: 0) {
            NotchContainer()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

private struct NotchContainer: View {
    @Environment(NotchViewModel.self) var vm
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var body: some View {
        let size = vm.shapeSize
        let shape = NotchShape(topRadius: vm.topRadius, bottomRadius: vm.bottomRadius)
        let simple = reduceMotion || vm.lowPower

        ZStack(alignment: .top) {
            switch vm.presentation {
            case .open:
                ExpandedNotchView()
                    .transition(
                        AsymmetricTransition(
                            insertion: RevealTransition(blur: simple ? 0 : 12, scale: 0.94, offset: CGSize(width: 0, height: -12))
                                .animation(simple ? Theme.reduced : Theme.content.delay(0.06)),
                            removal: OpacityTransition()
                                .animation(.easeOut(duration: 0.12))
                        )
                    )
            case .banner(let banner):
                BannerView(banner: banner)
                    .id(banner.id)
                    .transition(
                        AsymmetricTransition(
                            insertion: RevealTransition(blur: simple ? 0 : 8, scale: 0.9, offset: CGSize(width: 0, height: -6))
                                .animation(simple ? Theme.reduced : Theme.content.delay(0.08)),
                            removal: OpacityTransition()
                                .animation(.easeOut(duration: 0.12))
                        )
                    )
            case .closed:
                ClosedNotchView()
                    .transition(OpacityTransition().animation(.easeInOut(duration: 0.18)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .padding(.horizontal, vm.topRadius)
        .background(shape.fill(Color.black))
        .clipShape(shape)
        .overlay {
            if vm.isDropTargeted {
                shape
                    .stroke(Color.white.opacity(0.5), lineWidth: 1.5)
                    .transition(.opacity)
            }
        }
        .shadow(color: .black.opacity(shadowOpacity), radius: vm.isOpen ? 22 : 12, y: vm.isOpen ? 10 : 5)
        .contentShape(shape)
        .onDrop(of: [.fileURL], isTargeted: dropBinding) { providers in
            vm.handleDrop(providers)
        }
        .animation(shapeAnimation(simple: simple), value: size)
        .animation(shapeAnimation(simple: simple), value: vm.bottomRadius)
        .animation(Theme.micro, value: vm.isDropTargeted)
    }

    private var shadowOpacity: Double {
        switch vm.presentation {
        case .open: return 0.55
        case .banner: return 0.4
        case .closed: return 0
        }
    }

    private func shapeAnimation(simple: Bool) -> Animation {
        if simple { return Theme.reduced }
        switch vm.presentation {
        case .open: return Theme.open
        case .banner: return Theme.morph
        case .closed: return vm.isHovering ? Theme.hover : Theme.morph
        }
    }

    private var dropBinding: Binding<Bool> {
        Binding(
            get: { vm.isDropTargeted },
            set: { newValue in
                if vm.isDropTargeted != newValue { vm.isDropTargeted = newValue }
            }
        )
    }
}
