# Balnexa — copyright and contributions

`DRAFT — AI-generated` (Claude). It becomes authoritative once the project Owner confirms it. **This is not legal advice.** It records the project's position and the questions a lawyer should confirm.

## 1. Copyright holder and license

| Item | Value |
|---|---|
| Copyright holder | **Walter Luo, the author** (OD-LIC-1, revised 2026-11-14 05:35): the first owner of a work is its author (*Copyright Act* s. 13(1)). The Owner intends the copyright to belong to **Tambition Technologies Group Inc.**; the notice changes to the company only once a signed written assignment exists (§2, CR-1) |
| Notice | `NOTICE` at the repository root: `Copyright 2026 Walter Luo` |
| License | Apache License, Version 2.0 (`LICENSE`, unchanged from the official text). Apache-2.0 asks a project to attach the notice `Copyright [yyyy] [name of copyright owner]` with its own details; that is what `NOTICE` and `README.md` do. `LICENSE` itself is kept word for word |
| Effect of `NOTICE` | Under Apache-2.0 §4(d), anyone who redistributes the work must carry the `NOTICE` attributions along. The `NOTICE` file is informational and does not change the license |

## 2. What the notice does not settle by itself

The notice states a claim; it does not create ownership. Three points need the Owner's attention:

1. **Transfer from the people who wrote it.** Under Canada's *Copyright Act*, the author is the first owner of a work (s. 13(1)). The employer is the first owner only when the work is made by an employee under a contract of service, in the course of employment (s. 13(3)). Any other transfer is valid only **in writing, signed by the owner** of the right (s. 13(4)).
   - The human contributions in this repository come from the Owner, through the `walter-luo` account. If they were not made as an employee of the company, in the course of that employment, a short **signed written assignment from Walter Luo to Tambition Technologies Group Inc.** is what makes the company the owner.
   - Moral rights stay with the human author unless that author waives them. An assignment usually includes a waiver of moral rights.
2. **AI-generated material.** Most commits here were written by AI assistants (Claude, as well as the reviewers' reports from GPT-5 Codex).
   - The U.S. Copyright Office's January 2025 report (*Copyright and Artificial Intelligence, Part 2: Copyrightability*) concludes that wholly AI-generated material is not protected. Human selection, arrangement or modification can be protected.
   - Canadian law has no settled answer yet.
   - So the company's copyright may cover only the human-authored parts and the human selection and arrangement of the rest. The project does not depend on more than that: anyone may use the code under Apache-2.0 either way.
3. **Third-party components** keep their own copyright and licenses (`NOTICE`, last paragraph). Owner-private source material stays out of the repository under gate O-8.

## 3. Contributions from others

- **Inbound = outbound.** Apache-2.0 §5 says that a contribution intentionally submitted for inclusion is under the same license terms, unless the contributor states otherwise. Each contribution is therefore Apache-2.0. Its copyright stays with its author, and the company holds no more than the license.
- If the company wants to **own** outside contributions, or to relicense them later, it needs each contributor's written agreement: a contributor licence agreement or an assignment. The Owner decides whether to require one; until then, none is asked for.
- Review reports from independent AI reviewers (for example `docs/s4/reviews/g0/*`) are kept as records under the same license.

## 4. Open points for the Owner

| ID | Question |
|---|---|
| CR-1 | **When** to sign the written assignment from Walter Luo to Tambition Technologies Group Inc. (and whether it includes a waiver of moral rights). Until then the notice names the author. On signing, `NOTICE` and `README.md` change to the company in one commit, and this note records the date (never the document itself) |
| CR-2 | Should outside contributors sign a CLA or assignment, or is inbound = outbound under Apache-2.0 enough? |
| CR-3 | Should source files carry a short header (`Copyright 2026 <holder>. SPDX-License-Identifier: Apache-2.0`)? Apache-2.0 recommends it but does not require it. Adding headers would touch every file; committed migrations would need the header only in new migrations, because they are never edited |

## Sources

- Canada, *Copyright Act* (R.S.C. 1985, c. C-42), s. 13: https://laws-lois.justice.gc.ca/eng/acts/C-42/page-3.html
- Apache License, Version 2.0, §4(d), §5 and the Appendix: https://www.apache.org/licenses/LICENSE-2.0
- U.S. Copyright Office, *Copyright and Artificial Intelligence, Part 2: Copyrightability* (January 2025): https://www.copyright.gov/ai/Copyright-and-Artificial-Intelligence-Part-2-Copyrightability-Report.pdf
