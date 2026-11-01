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

    private var spring: Animation { .spring(response: 0.42, dampingFraction: 0.78) }

    var body: some View {
        let size = vm.shapeSize
        let shape = NotchShape(topRadius: vm.topRadius, bottomRadius: vm.bottomRadius)

        ZStack(alignment: .top) {
            if vm.isOpen {
                ExpandedNotchView()
                    .transition(
                        AnyTransition.asymmetric(
                            insertion: AnyTransition.opacity
                                .combined(with: AnyTransition.scale(scale: 0.92, anchor: .top))
                                .animation(spring.delay(0.05)),
                            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.12))
                        )
                    )
            } else {
                ClosedNotchView()
                    .transition(AnyTransition.opacity.animation(.easeInOut(duration: 0.18)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .padding(.horizontal, vm.topRadius)
        .background(shape.fill(Color.black))
        .clipShape(shape)
        .overlay {
            if vm.isDropTargeted {
                shape
                    .stroke(Color.accentColor.opacity(0.9), lineWidth: 2)
                    .blur(radius: 0.5)
            }
        }
        .shadow(color: .black.opacity(vm.isOpen ? 0.55 : 0), radius: 18, y: 8)
        .contentShape(shape)
        .onDrop(of: [.fileURL], isTargeted: dropBinding) { providers in
            vm.handleDrop(providers)
        }
        .animation(spring, value: vm.isOpen)
        .animation(spring, value: vm.activity)
        .animation(spring, value: vm.notchSize)
    }

    private var dropBinding: Binding<Bool> {
        Binding(
            get: { vm.isDropTargeted },
            set: { vm.isDropTargeted = $0 }
        )
    }
}
