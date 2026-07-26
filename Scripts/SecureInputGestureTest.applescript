use scripting additions

set instructions to "This hidden-answer field enables macOS Secure Event Input while it remains focused.

With the insertion point in the field, test the MX Master Sense Panel:

• Short click — Mission Control
• Hold and drag left — progressively reveal the next/right Space
• Hold and drag right — progressively reveal the previous/left Space
• Reverse while held — the same live gesture should reverse immediately

Mission Control or a Space change may take focus away. Return to this dialog and refocus the hidden field before each separate test.

Choose Finish when done."

tell application "System Events"
    activate
    try
        display dialog instructions default answer "" with hidden answer buttons {"Finish"} default button "Finish" giving up after 600 with title "MX Master Secure Input Test"
    on error number -128
        -- Closing the dialog is also a normal end to the test.
    end try
end tell
