@testable import FuturaTerm
import Testing

struct SidebarRowAccessibilityTests {
    @Test
    func folder_value_is_expanded_or_collapsed() {
        #expect(SidebarRowAccessibility.folderValue(isExpanded: true) == "expanded")
        #expect(SidebarRowAccessibility.folderValue(isExpanded: false) == "collapsed")
    }

    @Test
    func project_label_appends_remote_and_skips_the_comma_when_the_name_is_empty() {
        #expect(
            SidebarRowAccessibility.projectLabel(name: "futuraterm", isRemote: false)
                == "futuraterm"
        )
        #expect(
            SidebarRowAccessibility.projectLabel(name: "lab", isRemote: true)
                == "lab, remote"
        )
        #expect(SidebarRowAccessibility.projectLabel(name: "", isRemote: true) == "remote")
        #expect(SidebarRowAccessibility.projectLabel(name: "", isRemote: false).isEmpty)
    }

    @Test
    func tab_value_omits_live_local_and_joins_unloaded_and_pinned() {
        #expect(SidebarRowAccessibility.tabValue(isUnloaded: false, isPinned: false) == nil)
        #expect(
            SidebarRowAccessibility.tabValue(isUnloaded: true, isPinned: false)
                == "unloaded"
        )
        #expect(
            SidebarRowAccessibility.tabValue(isUnloaded: false, isPinned: true)
                == "pinned"
        )
        #expect(
            SidebarRowAccessibility.tabValue(isUnloaded: true, isPinned: true)
                == "unloaded, pinned"
        )
    }
}
