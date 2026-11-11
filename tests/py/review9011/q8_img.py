"""Q8 image hiding places (PNG and JPEG are the only accepted image formats)."""
from common import *
from PIL import Image, ImageDraw, ImageFont, PngImagePlugin


def render(lines, size=44, fg="black", bg="white", w=1400, mode="RGB", pos=(60, 60)):
    font = ImageFont.load_default(size=size)
    im = Image.new(mode if mode in ("RGB", "RGBA", "L") else "RGB", (w, 120 + 90 * len(lines)), bg)
    dr = ImageDraw.Draw(im)
    for i, ln in enumerate(lines):
        dr.text((pos[0], pos[1] + 90 * i), ln, fill=fg, font=font)
    return im


def png(im, **kw):
    b = io.BytesIO(); im.save(b, "PNG", **kw); return b.getvalue()


def jpeg(im, **kw):
    b = io.BytesIO(); im.convert("RGB").save(b, "JPEG", quality=92, **kw); return b.getvalue()


def vline(kind="luhn", seed=1):
    return "Ref " + val(kind, seed)


def chunk(typ, data):
    c = struct.pack(">I", len(data)) + typ + data
    return c + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF)


@case("IMG-ctl-png-visible-ocr")
def IMG_ctl_png_visible_ocr():
    return png(render(["Synthetic", vline("luhn", 401)])), "x.png"


@case("IMG-ctl-jpeg-visible-ocr")
def IMG_ctl_jpeg_visible_ocr():
    return jpeg(render(["Synthetic", vline("luhn", 402)])), "x.jpg"


@case("IMG-ctl-png-text-chunk")
def IMG_ctl_png_text_chunk():
    info = PngImagePlugin.PngInfo(); info.add_text("Comment", "Ref " + val("luhn", 403))
    return png(render(["Synthetic"]), pnginfo=info), "x.png"


@case("IMG-ctl-exif-imagedescription")
def IMG_ctl_exif_imagedescription():
    ex = Image.Exif(); ex[0x010E] = "Ref " + val("luhn", 404)
    return jpeg(render(["Synthetic"]), exif=ex), "x.jpg"


@case("IMG-exif-usercomment-in-exif-ifd")
def IMG_exif_usercomment_in_exif_ifd():
    v = val("luhn", 405)
    ex = Image.Exif()
    ex[0x8769] = {0x9286: b"ASCII\0\0\0Ref " + v.encode()}
    d = jpeg(render(["Synthetic"]), exif=ex)
    chk = Image.open(io.BytesIO(d)).getexif().get_ifd(0x8769)
    assert 0x9286 in chk                      # builder sanity: the tag is really in the file
    return d, "x.jpg"


@case("IMG-exif-xpcomment-utf16")
def IMG_exif_xpcomment_utf16():
    ex = Image.Exif(); ex[0x9C9C] = ("Ref " + val("luhn", 406)).encode("utf-16-le") + b"\0\0"
    return jpeg(render(["Synthetic"]), exif=ex), "x.jpg"


@case("IMG-exif-makernote-or-gps-ifd")
def IMG_exif_makernote_or_gps_ifd():
    ex = Image.Exif(); ex[0x8825] = {0x001D: "Ref " + val("luhn", 407)}      # GPSDateStamp slot used as free text
    d = jpeg(render(["Synthetic"]), exif=ex)
    assert 0x001D in Image.open(io.BytesIO(d)).getexif().get_ifd(0x8825)
    return d, "x.jpg"


@case("IMG-jpeg-two-com-segments-first-holds-value")
def IMG_jpeg_two_com_segments_first_holds_value():
    d = jpeg(render(["Synthetic"]))
    c1 = b"Ref " + val("luhn", 408).encode(); c2 = b"second comment"
    seg = lambda t: b"\xff\xfe" + struct.pack(">H", len(t) + 2) + t
    return d[:2] + seg(c1) + seg(c2) + d[2:], "x.jpg"


@case("IMG-jpeg-app15-custom-segment")
def IMG_jpeg_app15_custom_segment():
    d = jpeg(render(["Synthetic"]))
    t = b"Notes\0Ref " + val("luhn", 409).encode()
    return d[:2] + b"\xff\xef" + struct.pack(">H", len(t) + 2) + t + d[2:], "x.jpg"


@case("IMG-jpeg-trailing-data-after-eoi")
def IMG_jpeg_trailing_data_after_eoi():
    return jpeg(render(["Synthetic"])) + b"\r\nRef " + val("luhn", 410).encode() + b"\r\n", "x.jpg"


@case("IMG-png-trailing-data-after-iend")
def IMG_png_trailing_data_after_iend():
    return png(render(["Synthetic"])) + b"\r\nRef " + val("luhn", 411).encode() + b"\r\n", "x.png"


@case("IMG-png-private-ancillary-chunk")
def IMG_png_private_ancillary_chunk():
    d = png(render(["Synthetic"]))
    i = d.rfind(b"IEND") - 4
    return d[:i] + chunk(b"prVt", b"Ref " + val("luhn", 412).encode()) + d[i:], "x.png"


@case("IMG-png-itxt-xmp-attribute-form-control")
def IMG_png_itxt_xmp_attribute_form_control():
    x = '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Label="Ref %s"/></rdf:RDF></x:xmpmeta>' % val("luhn", 413)
    info = PngImagePlugin.PngInfo(); info.add_itxt("XML:com.adobe.xmp", x)
    return png(render(["Synthetic"]), pnginfo=info), "x.png"


@case("IMG-apng-default-image-clean-animation-frame-has-value")
def IMG_apng_default_image_clean_animation_frame_has_value():
    a = render(["Synthetic"]); b = render(["Synthetic", vline("luhn", 414)])
    return png(a, save_all=True, append_images=[b], default_image=True, duration=100, loop=0), "x.png"


@case("IMG-apng-frame0-clean-frame1-value")
def IMG_apng_frame0_clean_frame1_value():
    a = render(["Synthetic"]); b = render(["Synthetic", vline("luhn", 415)])
    return png(a, save_all=True, append_images=[b], duration=[10, 5000], loop=0), "x.png"


@case("IMG-mpo-second-picture-has-value")
def IMG_mpo_second_picture_has_value():
    a = render(["Synthetic"]).convert("RGB"); b = render(["Synthetic", vline("luhn", 416)]).convert("RGB")
    bio = io.BytesIO(); a.save(bio, "MPO", save_all=True, append_images=[b])
    d = bio.getvalue()
    assert d.startswith(b"\xff\xd8\xff")
    return d, "x.jpg"


@case("IMG-rgba-transparent-black-background")
def IMG_rgba_transparent_black_background():
    t = render(["Synthetic", vline("luhn", 417)], fg=(0, 0, 0, 255), bg=(0, 0, 0, 0), mode="RGBA")
    return png(t), "x.png"


@case("IMG-rgba-white-text-on-transparent-over-dark-page", note="alpha dropped: text colour == background colour after convert")
def IMG_rgba_white_text_on_transparent_over_dark_page():
    # text pixels: dark grey opaque; background: dark grey fully transparent  -> after dropping alpha nothing is left
    t = render(["Synthetic", vline("luhn", 418)], fg=(40, 40, 40, 255), bg=(40, 40, 40, 0), mode="RGBA")
    return png(t), "x.png"


@case("IMG-la-grayscale-alpha-transparent-bg")
def IMG_la_grayscale_alpha_transparent_bg():
    t = render(["Synthetic", vline("luhn", 419)], fg="black", bg="white").convert("L")
    alpha = t.point(lambda p: 255 if p < 128 else 0)       # opaque where the text is
    la = Image.merge("LA", (Image.new("L", t.size, 0), alpha))
    return png(la), "x.png"


@case("IMG-16bit-grayscale-png")
def IMG_16bit_grayscale_png():
    g = render(["Synthetic", vline("luhn", 420)]).convert("L").convert("I")
    g16 = g.point(lambda p: p * 100)           # background 25500, text 0 .. all below 65535: realistic low-gain 16-bit scan
    g16 = g16.convert("I;16")
    return png(g16), "x.png"


@case("IMG-exif-orientation-6-stored-sideways")
def IMG_exif_orientation_6_stored_sideways():
    up = render(["Synthetic", vline("luhn", 421)]).convert("RGB")
    ex = Image.Exif(); ex[0x0112] = 6
    return jpeg(up.rotate(90, expand=True), exif=ex), "x.jpg"


@case("IMG-rotated-90-pixels")
def IMG_rotated_90_pixels():
    return png(render(["Synthetic", vline("luhn", 422)]).rotate(90, expand=True)), "x.png"


@case("IMG-rotated-180-pixels")
def IMG_rotated_180_pixels():
    return png(render(["Synthetic", vline("luhn", 423)]).rotate(180)), "x.png"


@case("IMG-mirrored")
def IMG_mirrored():
    from PIL import ImageOps
    return png(ImageOps.mirror(render(["Synthetic", vline("luhn", 424)]))), "x.png"


@case("IMG-skewed-12-degrees")
def IMG_skewed_12_degrees():
    return png(render(["Synthetic", vline("luhn", 425)]).rotate(12, expand=True, fillcolor="white")), "x.png"


@case("IMG-low-contrast-light-grey")
def IMG_low_contrast_light_grey():
    return png(render(["Synthetic", vline("luhn", 426)], fg=(225, 225, 225))), "x.png"


@case("IMG-mid-contrast-grey-on-white")
def IMG_mid_contrast_grey_on_white():
    return png(render(["Synthetic", vline("luhn", 427)], fg=(170, 170, 170))), "x.png"


@case("IMG-small-font-10px")
def IMG_small_font_10px():
    return png(render(["Synthetic", vline("luhn", 428)], size=10)), "x.png"


@case("IMG-small-font-14px")
def IMG_small_font_14px():
    return png(render(["Synthetic", vline("luhn", 429)], size=14)), "x.png"


@case("IMG-sparse-corner-on-large-page")
def IMG_sparse_corner_on_large_page():
    im = Image.new("RGB", (2480, 3508), "white")
    ImageDraw.Draw(im).text((1900, 3300), vline("luhn", 430), fill="black", font=ImageFont.load_default(size=22))
    return png(im), "x.png"


@case("IMG-light-text-on-dark-control")
def IMG_light_text_on_dark_control():
    return png(render(["Synthetic", vline("luhn", 431)], fg="white", bg="black")), "x.png"


@case("IMG-ocr-split-by-wide-gap-between-groups")
def IMG_ocr_split_by_wide_gap_between_groups():
    v = val("luhn", 432, "none")
    font = ImageFont.load_default(size=44)
    im = Image.new("RGB", (1800, 160), "white"); dr = ImageDraw.Draw(im)
    x = 60
    for g in (v[:3], v[3:6], v[6:]):
        dr.text((x, 60), g, fill="black", font=font); x += 360
    return png(im), "x.png"


@case("IMG-two-columns-value-in-second-column")
def IMG_two_columns_value_in_second_column():
    im = Image.new("RGB", (2400, 400), "white"); dr = ImageDraw.Draw(im); f = ImageFont.load_default(size=40)
    for k in range(4):
        dr.text((60, 40 + 80 * k), "Synthetic left column text %d" % k, fill="black", font=f)
        dr.text((1300, 40 + 80 * k), ("Ref " + val("luhn", 433)) if k == 2 else "right column text %d" % k, fill="black", font=f)
    return png(im), "x.png"


@case("IMG-iptc-caption-control")
def IMG_iptc_caption_control():
    cap = b"Ref " + val("luhn", 434).encode()
    iptc = b"\x1c\x02\x78" + struct.pack(">H", len(cap)) + cap
    irb = b"Photoshop 3.0\x00" + b"8BIM" + b"\x04\x04" + b"\x00\x00" + struct.pack(">I", len(iptc)) + iptc + (b"\x00" if len(iptc) % 2 else b"")
    d = jpeg(render(["Synthetic"]))
    return d[:2] + b"\xff\xed" + struct.pack(">H", len(irb) + 2) + irb + d[2:], "x.jpg"
