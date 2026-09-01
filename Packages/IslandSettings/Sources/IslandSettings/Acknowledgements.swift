import Foundation

/// Third-party components Isleta ships, and the notices shipping them obliges us to show.
///
/// This is not a courtesy page. `mediaremote-adapter` is BSD 3-Clause, and clause 2 requires that a
/// binary distribution **reproduce the copyright notice, the list of conditions and the disclaimer**
/// in "the documentation and/or other materials provided with the distribution". Sparkle is MIT,
/// whose one condition is the same shape: the notice "shall be included in all copies or substantial
/// portions of the Software". A license file sitting in the source tree does not satisfy either,
/// because the source tree is not what users are given — the app is. So the full text ships inside
/// the bundle and is reachable from Settings.
///
/// `AcknowledgementTests` asserts the text here is byte-identical to the `LICENSE` on disk, so the
/// two cannot drift and a future edit that guts this file fails the build rather than quietly
/// shipping a license violation.
public struct Acknowledgement: Identifiable, Equatable, Sendable {

    public var id: String { name }

    /// The component, as its authors name it.
    public let name: String

    /// The upstream project, for someone who wants to check what we did with it.
    public let url: URL

    /// Why it is in Isleta at all. Users reading an acknowledgements list are usually asking what a
    /// third party is doing inside an app that sits over their menu bar; answering is cheap.
    public let purpose: String

    /// The one line clause 2 is really about.
    public let copyrightNotice: String

    /// Short name, for the row.
    public let licenseName: String

    /// The complete license, verbatim. Not a summary and not a link: clause 2 asks for the
    /// conditions and the disclaimer themselves, and a link is not a reproduction.
    public let licenseText: String

    public init(
        name: String,
        url: URL,
        purpose: String,
        copyrightNotice: String,
        licenseName: String,
        licenseText: String
    ) {
        self.name = name
        self.url = url
        self.purpose = purpose
        self.copyrightNotice = copyrightNotice
        self.licenseName = licenseName
        self.licenseText = licenseText
    }
}

public enum Acknowledgements {

    /// Everything Isleta bundles, in the order it is shown.
    ///
    /// An entry earns its place by being *in the binary* — an acknowledgement for code that is not
    /// shipped is its own kind of inaccuracy, and this list was deliberately one entry long for as
    /// long as Sparkle was only a seam. Sparkle became a linked dependency of the app target for
    /// 1.0.0, so it belongs here now; the obligation attaches to the distributed build, not to the
    /// decision to add it.
    public static let all: [Acknowledgement] = [mediaRemoteAdapter, sparkle]

    public static let mediaRemoteAdapter = Acknowledgement(
        name: "mediaremote-adapter",
        url: URL(string: "https://github.com/ungive/mediaremote-adapter")!,
        purpose: settingsText("about.acknowledgement.mediaRemoteAdapter", """
            Reads what is currently playing. Apple restricted the Now Playing API to its own \
            processes in macOS 15.4, and this is the supported way back to it.
            """),
        copyrightNotice: "Copyright (c) 2025, Jonas van den Berg and contributors",
        licenseName: "BSD 3-Clause",
        licenseText: bsd3Clause
    )

    public static let sparkle = Acknowledgement(
        name: "Sparkle",
        url: URL(string: "https://github.com/sparkle-project/Sparkle")!,
        purpose: settingsText("about.acknowledgement.sparkle", """
            Delivers Isleta's updates. It checks the appcast, verifies every download against the \
            EdDSA public key built into this copy of the app, and installs what it has verified.
            """),
        // MIT asks for "the above copyright notice", and Sparkle's is seven lines naming seven
        // holders across nineteen years. Reproducing one of them would be reproducing none of them.
        copyrightNotice: """
            Copyright (c) 2006-2013 Andy Matuschak. \
            Copyright (c) 2009-2013 Elgato Systems GmbH. \
            Copyright (c) 2011-2014 Kornel Lesiński. \
            Copyright (c) 2015-2017 Mayur Pawashe. \
            Copyright (c) 2014 C.W. Betts. \
            Copyright (c) 2014 Petroules Corporation. \
            Copyright (c) 2014 Big Nerd Ranch.
            """,
        licenseName: "MIT",
        licenseText: sparkleMIT
    )

    /// Verbatim from `Vendor/mediaremote-adapter/LICENSE`.
    static let bsd3Clause = """
        BSD 3-Clause License

        Copyright (c) 2025, Jonas van den Berg and contributors

        Redistribution and use in source and binary forms, with or without
        modification, are permitted provided that the following conditions are met:

        1. Redistributions of source code must retain the above copyright notice, this
           list of conditions and the following disclaimer.

        2. Redistributions in binary form must reproduce the above copyright notice,
           this list of conditions and the following disclaimer in the documentation
           and/or other materials provided with the distribution.

        3. Neither the name of the copyright holder nor the names of its
           contributors may be used to endorse or promote products derived from
           this software without specific prior written permission.

        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
        AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
        IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
        DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
        FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
        DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
        SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
        CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
        OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
        OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
        """

    /// Verbatim from `Vendor/Sparkle/LICENSE`, which is itself a copy of the `LICENSE` in the pinned
    /// SwiftPM checkout — see the README beside it for why a copy exists at all.
    ///
    /// The EXTERNAL LICENSES section below is not padding and is not ours to trim: bsdiff, sais,
    /// ed25519 and `SUSignatureVerifier.m` are compiled into the framework and its helper tools, and
    /// two of those four licenses carry their own binary-redistribution clause. Upstream ships them
    /// as one file for that reason, so Isleta does too.
    static let sparkleMIT = """
        Copyright (c) 2006-2013 Andy Matuschak.
        Copyright (c) 2009-2013 Elgato Systems GmbH.
        Copyright (c) 2011-2014 Kornel Lesiński.
        Copyright (c) 2015-2017 Mayur Pawashe.
        Copyright (c) 2014 C.W. Betts.
        Copyright (c) 2014 Petroules Corporation.
        Copyright (c) 2014 Big Nerd Ranch.
        All rights reserved.

        Permission is hereby granted, free of charge, to any person obtaining a copy of
        this software and associated documentation files (the "Software"), to deal in
        the Software without restriction, including without limitation the rights to
        use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
        the Software, and to permit persons to whom the Software is furnished to do so,
        subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
        FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
        COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
        IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
        CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

        =================
        EXTERNAL LICENSES
        =================

        bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

        Copyright 2003-2005 Colin Percival
        All rights reserved

        Redistribution and use in source and binary forms, with or without
        modification, are permitted providing that the following conditions 
        are met:
        1. Redistributions of source code must retain the above copyright
           notice, this list of conditions and the following disclaimer.
        2. Redistributions in binary form must reproduce the above copyright
           notice, this list of conditions and the following disclaimer in the
           documentation and/or other materials provided with the distribution.

        THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
        IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
        WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
        ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
        DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
        DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
        OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
        HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
        STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
        IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
        POSSIBILITY OF SUCH DAMAGE.

        --

        sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

        The sais-lite copyright is as follows:

        Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

        Permission is hereby granted, free of charge, to any person
        obtaining a copy of this software and associated documentation
        files (the "Software"), to deal in the Software without
        restriction, including without limitation the rights to use,
        copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the
        Software is furnished to do so, subject to the following
        conditions:

        The above copyright notice and this permission notice shall be
        included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
        EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
        OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
        NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
        HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
        WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
        FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
        OTHER DEALINGS IN THE SOFTWARE.

        --

        Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

        Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

        This software is provided 'as-is', without any express or implied warranty. In no event will the
        authors be held liable for any damages arising from the use of this software.

        Permission is granted to anyone to use this software for any purpose, including commercial
        applications, and to alter it and redistribute it freely, subject to the following restrictions:

        1. The origin of this software must not be misrepresented; you must not claim that you wrote the
           original software. If you use this software in a product, an acknowledgment in the product
           documentation would be appreciated but is not required.

        2. Altered source versions must be plainly marked as such, and must not be misrepresented as
           being the original software.

        3. This notice may not be removed or altered from any source distribution.

        --

        SUSignatureVerifier.m:

        Copyright (c) 2011 Mark Hamlin.

        All rights reserved.

        Redistribution and use in source and binary forms, with or without
        modification, are permitted providing that the following conditions
        are met:
        1. Redistributions of source code must retain the above copyright
           notice, this list of conditions and the following disclaimer.
        2. Redistributions in binary form must reproduce the above copyright
           notice, this list of conditions and the following disclaimer in the
           documentation and/or other materials provided with the distribution.

        THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
        IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
        WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
        ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
        DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
        DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
        OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
        HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
        STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
        IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
        POSSIBILITY OF SUCH DAMAGE.
        """
}
