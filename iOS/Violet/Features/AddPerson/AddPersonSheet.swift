import SwiftUI
import UIKit

struct AddPersonSheet: View {
  enum PhotoSlot: String, Identifiable {
    case front = "Front"
    case left = "Left"
    case right = "Right"

    var id: String { rawValue }
  }

  private enum PhotoSource: String {
    case camera
    case photoLibrary
  }

  private struct PhotoSelection: Identifiable {
    let id = UUID()
    let slot: PhotoSlot
    let source: PhotoSource
  }

  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var relation = ""
  @State private var bio = ""
  @State private var yearMet = ""
  @State private var frontPhoto: Data?
  @State private var leftPhoto: Data?
  @State private var rightPhoto: Data?
  @State private var pendingPhotoSlot: PhotoSlot?
  @State private var activePhotoSelection: PhotoSelection?
  @State private var showsPhotoSourceOptions = false
  @State private var validationMessage: String?
  @State private var isSaving = false

  let onSave: (RelationshipDraft) async -> Bool

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          Text("Add three clear photos")
            .font(VioletDesign.heading(19))
            .foregroundStyle(VioletDesign.ink)

          HStack(spacing: 12) {
            photoButton(.front, data: frontPhoto)
            photoButton(.left, data: leftPhoto)
            photoButton(.right, data: rightPhoto)
          }

          fieldLabel("Name")
          TextField("Full name", text: $name)
            .textFieldStyle(VioletTextFieldStyle())
            .textContentType(.name)

          fieldLabel("Relationship")
          TextField("For example, daughter or doctor", text: $relation)
            .textFieldStyle(VioletTextFieldStyle())

          fieldLabel("Short bio")
          TextEditor(text: $bio)
            .font(VioletDesign.body(18))
            .foregroundStyle(VioletDesign.ink)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 108)
            .background(VioletDesign.softFill)
            .clipShape(RoundedRectangle(cornerRadius: VioletDesign.cornerRadius))

          fieldLabel("Year you met")
          TextField("For example, 1998", text: $yearMet)
            .keyboardType(.numberPad)
            .textFieldStyle(VioletTextFieldStyle())

          if let validationMessage {
            Text(validationMessage)
              .font(VioletDesign.body(15))
              .foregroundStyle(.red)
          }

          Button(isSaving ? "Saving…" : "Add person") {
            save()
          }
          .buttonStyle(VioletPrimaryButtonStyle())
          .disabled(isSaving)
          .opacity(isSaving ? 0.65 : 1)
          .padding(.top, 4)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 34)
      }
      .background(Color.white)
      .navigationTitle("Add someone")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(VioletDesign.ink)
              .frame(width: 34, height: 34)
          }
          .accessibilityLabel("Close")
        }
      }
      .confirmationDialog(
        photoSourceTitle,
        isPresented: $showsPhotoSourceOptions,
        titleVisibility: .visible
      ) {
        Button("Take Photo") {
          beginPhotoSelection(from: .camera)
        }
        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

        Button("Choose from Photo Library") {
          beginPhotoSelection(from: .photoLibrary)
        }

        Button("Cancel", role: .cancel) {}
      }
      .fullScreenCover(item: $activePhotoSelection) { selection in
        CameraCaptureView(
          title: "\(selection.slot.rawValue) photo",
          sourceType: selection.source == .camera ? .camera : .photoLibrary
        ) { image in
          guard let data = image.jpegData(compressionQuality: 0.86) else { return }
          switch selection.slot {
          case .front: frontPhoto = data
          case .left: leftPhoto = data
          case .right: rightPhoto = data
          }
        }
        .ignoresSafeArea()
      }
    }
  }

  private func fieldLabel(_ text: String) -> some View {
    Text(text)
      .font(VioletDesign.heading(16))
      .foregroundStyle(VioletDesign.ink)
      .padding(.bottom, -16)
  }

  private func photoButton(_ slot: PhotoSlot, data: Data?) -> some View {
    Button {
      pendingPhotoSlot = slot
      showsPhotoSourceOptions = true
    } label: {
      VStack(spacing: 8) {
        Group {
          if let data, let image = UIImage(data: data) {
            Image(uiImage: image)
              .resizable()
              .scaledToFill()
          } else {
            Image(systemName: "camera.fill")
              .font(.system(size: 24))
              .foregroundStyle(VioletDesign.deepAccent)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(VioletDesign.softFill)
          }
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: VioletDesign.cornerRadius))

        Text(slot.rawValue)
          .font(VioletDesign.body(15))
          .foregroundStyle(VioletDesign.ink)
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Add \(slot.rawValue.lowercased()) photo")
  }

  private var photoSourceTitle: String {
    guard let pendingPhotoSlot else { return "Add photo" }
    return "Add \(pendingPhotoSlot.rawValue.lowercased()) photo"
  }

  private func beginPhotoSelection(from source: PhotoSource) {
    guard let pendingPhotoSlot else { return }
    activePhotoSelection = PhotoSelection(slot: pendingPhotoSlot, source: source)
    self.pendingPhotoSlot = nil
  }

  private func save() {
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanRelation = relation.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanName.isEmpty, !cleanRelation.isEmpty, !cleanBio.isEmpty,
      let year = Int(yearMet), (1900...Calendar.current.component(.year, from: .now)).contains(year),
      let frontPhoto, let leftPhoto, let rightPhoto
    else {
      validationMessage = "Add all three photos, a name, relationship, bio, and a valid year."
      return
    }

    validationMessage = nil
    isSaving = true
    let draft = RelationshipDraft(
      name: cleanName,
      frontPhoto: frontPhoto,
      leftPhoto: leftPhoto,
      rightPhoto: rightPhoto,
      relation: cleanRelation,
      bio: cleanBio,
      yearMet: year
    )
    Task {
      if await onSave(draft) {
        dismiss()
      } else {
        isSaving = false
        validationMessage = "You can add up to \(AppLimits.maximumPeople) people."
      }
    }
  }
}
