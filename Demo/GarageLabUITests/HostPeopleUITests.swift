import XCTest

/// MVCALE-122: GarageKit shows the host's names (and falls back to the server's)
/// on the owner screens. Runs GarageLab against its in-memory demo server
/// (LAB_DEMO=1): no backend, no sign-in.
///
/// The demo has three contacts the server calls "Avery Backend", "Blake Backend"
/// and "Casey Backend". The Lab's fake host calls Avery "Avery (host)" and Casey
/// "Casey (host)", and knows nothing about Blake. Avery already has the door.
final class HostPeopleUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["LAB_DEMO"] = "1"
    }

    private func text(_ s: String) -> XCUIElement { app.staticTexts[s].firstMatch }

    private func openDoorProfile() {
        // The demo opens on the owner screens (the dial's animation never idles).
        let door = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo door'")).firstMatch
        XCTAssertTrue(door.waitForExistence(timeout: 10), "the demo door is listed for its owner")
        door.tap()
        XCTAssertTrue(text("Who can open it").waitForExistence(timeout: 10))
    }

    /// Ends the search (iOS 26 shows its own "close" while searching and hides
    /// the toolbar's Cancel), then cancels the sheet.
    private func dismissShareSheet() {
        let closeSearch = app.buttons["close"].firstMatch
        if closeSearch.exists { closeSearch.tap() }
        for label in ["Cancel", "Close"] {
            let b = app.buttons[label].firstMatch
            if b.waitForExistence(timeout: 3) { b.tap(); break }
        }
        XCTAssertTrue(text("Who can open it").waitForExistence(timeout: 10), "back on the door profile")
    }

    /// The host wins, a rename shows live, and turning the host off falls back.
    func testHostNamesWinUpdateLiveAndFallBack() {
        app.launch()
        openDoorProfile()

        // Host wins on the "who can open it" row.
        XCTAssertTrue(text("Avery (host)").waitForExistence(timeout: 10), "the host's name, not the server's")
        XCTAssertFalse(text("Avery Backend").exists)

        // Share sheet: host names where the host has one, the server's otherwise,
        // sorted by the shown name, and search matches the shown name.
        app.buttons["Share…"].firstMatch.tap()
        XCTAssertTrue(text("Casey (host)").waitForExistence(timeout: 10))
        XCTAssertTrue(text("Blake Backend").exists, "no host name: the server's")
        XCTAssertFalse(text("Casey Backend").exists)
        XCTAssertLessThan(text("Blake Backend").frame.minY, text("Casey (host)").frame.minY,
                          "sorted by the shown name: Blake Backend, then Casey (host)")
        let search = app.searchFields.firstMatch
        if search.waitForExistence(timeout: 3) {
            search.tap()
            search.typeText("host")
            XCTAssertTrue(text("Casey (host)").waitForExistence(timeout: 5))
            XCTAssertFalse(text("Blake Backend").exists, "search matches the shown name")
        }
        dismissShareSheet()

        // A rename in the host redraws the open screen.
        XCTAssertTrue(text("Avery (host)").waitForExistence(timeout: 10))
        app.buttons["lab.rename"].tap()
        XCTAssertTrue(text("Avery renamed").waitForExistence(timeout: 5), "a host rename shows without reopening")
        XCTAssertFalse(text("Avery (host)").exists)

        // Host off: back to the server's name.
        app.descendants(matching: .any)["lab.hostPeople"].firstMatch.tap()
        XCTAssertTrue(text("Avery Backend").waitForExistence(timeout: 5), "no host: the server's name")
        XCTAssertFalse(text("Avery renamed").exists)
    }

    /// Starting with no host at all is exactly the kit's old behaviour.
    func testNoHostShowsTheServersNames() {
        app.launchEnvironment["LAB_HOST_PEOPLE"] = "0"
        app.launch()
        openDoorProfile()
        XCTAssertTrue(text("Avery Backend").waitForExistence(timeout: 10))
        XCTAssertFalse(text("Avery (host)").exists)
    }
}
