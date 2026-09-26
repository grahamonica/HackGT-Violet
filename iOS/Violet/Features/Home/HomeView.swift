import SwiftUI

struct HomeView: View {
  @Bindable var model: AppModel
  @State private var showsAddPerson = false

  private let columns = [
    GridItem(.adaptive(minimum: 138, maximum: 190), spacing: 24, alignment: .top)
  ]

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          glassesStatus

          if model.isLoading {
            ProgressView()
              .tint(VioletDesign.accent)
              .frame(maxWidth: .infinity, minHeight: 220)
          } else if model.people.isEmpty {
            emptyState
          } else {
            LazyVGrid(columns: columns, spacing: 28) {
              ForEach(model.people) { person in
                PersonBubble(person: person) {
                  Task { await model.readBio(for: person) }
                }
              }
            }
            .padding(.top, 4)
          }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 36)
      }
      .background(Color.white)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          HStack(spacing: 10) {
            Image("VioletLogo")
              .resizable()
              .scaledToFit()
              .frame(width: 38, height: 38)
              .accessibilityHidden(true)
            Text("Violet")
              .font(VioletDesign.heading(30, bold: true))
              .foregroundStyle(VioletDesign.ink)
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showsAddPerson = true
          } label: {
            Image(systemName: "plus")
              .font(.system(size: 17, weight: .semibold))
              .foregroundStyle(.white)
              .frame(width: 34, height: 34)
              .background(VioletDesign.deepAccent)
              .clipShape(RoundedRectangle(cornerRadius: VioletDesign.cornerRadius))
          }
          .accessibilityLabel("Add a familiar person")
        }
      }
      .toolbarBackground(.white, for: .navigationBar)
      .sheet(isPresented: $showsAddPerson) {
        AddPersonSheet { draft in
          await model.addPerson(draft)
        }
      }
    }
  }

  @ViewBuilder
  private var glassesStatus: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(statusColor)
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 1) {
        Text(model.glasses.state.label)
          .font(VioletDesign.body(17))
          .foregroundStyle(VioletDesign.ink)
        if model.isRecognizing {
          Text("Checking the image carefully…")
            .font(VioletDesign.body(14))
            .foregroundStyle(VioletDesign.muted)
        }
      }

      Spacer(minLength: 8)

      if needsSetupAction {
        Button("Set up") {
          Task { await model.enableGlasses() }
        }
        .font(VioletDesign.heading(14, bold: true))
        .foregroundStyle(VioletDesign.deepAccent)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(VioletDesign.softFill)
        .clipShape(RoundedRectangle(cornerRadius: VioletDesign.cornerRadius))
      }
    }
    .padding(.top, 8)
  }

  private var needsSetupAction: Bool {
    switch model.glasses.state {
    case .needsSetup, .unavailable: true
    default: false
    }
  }

  private var statusColor: Color {
    switch model.glasses.state {
    case .listening: VioletDesign.accent
    case .capturing: VioletDesign.deepAccent
    case .unavailable: .orange
    default: Color.gray.opacity(0.55)
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image("VioletLogo")
        .resizable()
        .scaledToFit()
        .frame(width: 96, height: 96)
        .opacity(0.9)
      Text("The people you know will appear here")
        .font(VioletDesign.heading(21))
        .foregroundStyle(VioletDesign.ink)
        .multilineTextAlignment(.center)
      Text("Use the plus button to add the first person.")
        .font(VioletDesign.body(17))
        .foregroundStyle(VioletDesign.muted)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, minHeight: 340)
    .padding(.horizontal, 30)
  }
}

private struct PersonBubble: View {
  let person: FamiliarPerson
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 10) {
        Group {
          if let image = UIImage(data: person.frontPhoto) {
            Image(uiImage: image)
              .resizable()
              .scaledToFill()
          } else {
            Image(systemName: "person.fill")
              .font(.system(size: 42))
              .foregroundStyle(VioletDesign.accent)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(VioletDesign.softFill)
          }
        }
        .frame(width: 132, height: 132)
        .clipShape(Circle())
        .overlay(Circle().stroke(VioletDesign.accent.opacity(0.3), lineWidth: 2))

        Text(person.name)
          .font(VioletDesign.heading(18))
          .foregroundStyle(VioletDesign.ink)
          .lineLimit(2)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(person.name), \(person.relation)")
    .accessibilityHint("Reads their biography aloud")
  }
}

