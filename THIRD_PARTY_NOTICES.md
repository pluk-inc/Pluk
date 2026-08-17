# Third-Party Notices

Pluk uses third-party software in addition to the source covered by the repository's AGPL-3.0 license.

- The vendored `BSON` package is provided under the MIT License in [`BSON/LICENSE`](./BSON/LICENSE).
- `js-beautify`, bundled as `pluk/Resources/js-beautify.min.js`, is provided under the MIT License by the [js-beautify contributors](https://github.com/beautifier/js-beautify).
- `sql-formatter`, bundled as `pluk/Resources/sql-formatter.min.js`, is provided under the MIT License by the [sql-formatter contributors](https://github.com/sql-formatter-org/sql-formatter).
- `valkey-swift`, used for Redis protocol connectivity, is provided under the Apache License 2.0 by the [Valkey contributors](https://github.com/valkey-io/valkey-swift); its [upstream notice](https://github.com/valkey-io/valkey-swift/blob/1.5.0/Notice.txt) is reproduced below.
- Swift Package Manager dependencies retain their respective upstream licenses. Their exact revisions and source repositories are recorded in `Pluk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

Database and service names and logos belong to their respective owners. Their inclusion indicates compatibility and does not imply endorsement.

## valkey-swift notice

Copyright 2025 The valkey-swift Project.

`valkey-swift` includes RESP3 and hash-slot work derived from
[RediStack](https://github.com/swift-server/RediStack) under Apache License
2.0, connection-pool work derived from
[postgres-nio](https://github.com/vapor/postgres-nio) under the MIT License,
and hash-slot update logic influenced by
[valkey-glide](https://github.com/valkey-io/valkey-glide) under Apache License
2.0.

It also includes CRC16 code derived from work by Georges Menie and adapted to
Redis style by Salvatore Sanfilippo:

> Copyright 2001-2010 Georges Menie (www.menie.org)
>
> Copyright 2010 Salvatore Sanfilippo (adapted to Redis coding style)
>
> All rights reserved.
>
> Redistribution and use in source and binary forms, with or without
> modification, are permitted provided that the following conditions are met:
>
> - Redistributions of source code must retain the above copyright notice,
>   this list of conditions and the following disclaimer.
> - Redistributions in binary form must reproduce the above copyright notice,
>   this list of conditions and the following disclaimer in the documentation
>   and/or other materials provided with the distribution.
> - Neither the name of the University of California, Berkeley nor the names
>   of its contributors may be used to endorse or promote products derived
>   from this software without specific prior written permission.
>
> THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS "AS IS" AND ANY
> EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
> WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
> DISCLAIMED. IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE FOR ANY
> DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
> (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
> LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
> ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
> (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
> THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
