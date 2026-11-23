/<meta name="viewport"/ {
    viewport++
    print "    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes\">"
    next
}

/<\/head>/ {
    head++
    print "    <link rel=\"stylesheet\" href=\"app/styles/firefox-input.css?v=UNIQUE_VERSION\">"
}

/^[[:space:]]*UI[.]start[(][)];/ {
    start++
    # Load the extension dynamically so that a missing or broken module can
    # never prevent the upstream client from starting.
    print "        try {"
    print "            const { default: installFirefoxInput } = await import(\"./app/firefox-input.js?v=UNIQUE_VERSION\");"
    print "            installFirefoxInput(UI);"
    print "        } catch (error) {"
    print "            console.error(\"Firefox input extension disabled:\", error);"
    print "        }"
}

{ print }

END {
    if (viewport != 1 || head != 1 || start != 1) {
        print "ERROR: Unsupported noVNC bootstrap; refusing to build an unpatched image." > "/dev/stderr"
        exit 1
    }
}
