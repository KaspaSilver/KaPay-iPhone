import SwiftUI

/// The notices the libraries KaPay ships ask to travel with it - only what is in the
/// binary (WebRTC and Opus left with calls and voice notes). BoringSSL (OpenSSL) requires
/// its notice in the binary's documentation; the Apache, MIT and ISC ones ask for
/// attribution. Plain scrolling text, one card per library.
struct OpenSourceLicensesView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Notice: Identifiable {
        let id: String
        let name: String
        let license: String
        let holder: String
        let text: String
    }

    private static let bsd3 = """
Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
"""

    private static let apache2 = """
Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
"""

    private static let mit = """
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
"""

    private static let isc = """
Permission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

This product includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit (http://www.openssl.org/). This product includes cryptographic software written by Eric Young (eay@cryptsoft.com).
"""

    private static let notices: [Notice] = [
        Notice(id: "grpc-swift", name: "grpc-swift", license: "Apache License 2.0", holder: "Copyright 2015-2024, gRPC Authors", text: apache2),
        Notice(id: "swift-protobuf", name: "SwiftProtobuf", license: "Apache License 2.0", holder: "Copyright 2014-2024 Apple Inc. and the SwiftProtobuf project authors", text: apache2),
        Notice(id: "swift-nio", name: "SwiftNIO, swift-crypto, swift-log and the Swift Server ecosystem packages", license: "Apache License 2.0", holder: "Copyright 2017-2024 Apple Inc. and the SwiftNIO project authors", text: apache2),
        Notice(id: "boringssl", name: "BoringSSL (in swift-nio-ssl)", license: "ISC and OpenSSL", holder: "Copyright 1995-2016 The OpenSSL Project Authors; Copyright 1995-1998 Eric Young; Copyright Google Inc.", text: isc),
        Notice(id: "llhttp", name: "llhttp (in SwiftNIO)", license: "MIT", holder: "Copyright Fedor Indutny, 2018.", text: mit),
        Notice(id: "secp256k1", name: "swift-secp256k1 (P256K) and libsecp256k1", license: "MIT", holder: "Copyright (c) 2021 21.dev and the swift-secp256k1 authors; Copyright (c) 2013 Pieter Wuille", text: mit),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("KaPay is built with these open source libraries. Their authors ask that these notices travel with the app.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    ForEach(Self.notices) { notice in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(notice.name).font(.headline)
                                Spacer()
                                Text(notice.license)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                            }
                            Text(notice.holder)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(notice.text)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.regularMaterial)
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.8))
                        )
                    }
                }
                .padding(16)
            }
            .navigationTitle("Open Source Licenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
