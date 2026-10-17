import PaseoKit
import Testing
@testable import Garbeo

@Suite struct NewProjectDraftTests {
    @Test func emptyPathDisablesCreateWithoutAnError() {
        let draft = NewProjectDraft(path: "  ")
        #expect(draft.projectPath == nil)
        #expect(draft.problem == nil)
        #expect(draft.namePrompt == "Automatic")
    }

    @Test func relativePathIsAProblem() {
        let draft = NewProjectDraft(path: "code/app")
        #expect(draft.projectPath == nil)
        #expect(draft.problem == ProjectPath.Problem.notAbsolute.localizedDescription)
    }

    @Test func validPathSuggestsItsName() {
        let draft = NewProjectDraft(path: "~/code/my-app/")
        #expect(draft.projectPath?.path == "~/code/my-app")
        #expect(draft.problem == nil)
        #expect(draft.namePrompt == "my-app")
    }

    @Test func customNameOnlyWhenItDiffers() {
        #expect(NewProjectDraft(path: "/srv/app", name: "  ").customName == nil)
        #expect(NewProjectDraft(path: "/srv/app", name: "app").customName == nil)
        #expect(NewProjectDraft(path: "/srv/app", name: " My App ").customName == "My App")
    }
}
