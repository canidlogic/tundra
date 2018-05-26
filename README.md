# Tundra
## 1. Introduction
Tundra is a multimedia editing framework for raster images, sound, and video that follows the Unix philosophy.  Instead of being a large, monolithic editing program, Tundra is a set of small programs which can work together to accomplish sophisticated multimedia editing objectives.  The idea is similar to NetPBM, except Tundra is designed for handling video and sound in addition to individual raster images.

The basis of Tundra is an image format called Spot and an audio format called Kaltag.  These formats are extremely simple, with all unnecessary complexity removed.  Tundra provides programs that can convert between these formats and more commonly used image, video, and sound formats.  Apart from the conversion programs, all Tundra programs exclusively use the Spot and/or Kaltag formats to avoid complexity in their implementation.

Tundra is based on an older video editing system of the same name that was used on a few short film projects but never publicly released.  The older Tundra version was written in Java using a complex object-oriented abstraction.  The new Tundra version is written in C and intends to have a much simpler (but just as capable) design.

## 2. Status
As of May 26, 2018, Tundra is currently in the early alpha stages of development.  Basic features will be added in the near future to allow for basic editing operations and basic format conversions.  The framework will be developed out from there.

## 3. Spot image format
The Spot image format is stored as a sequence of 32-bit unsigned integers.  The first integer always has the value 0x72edf078.  Tundra programs always write the integers in the platform-specific endian order (either little endian, where the least significant byte is first, or big endian, where the most significant byte is first).  When reading, if the first integer has the value 0x78f0ed72, the Tundra program will report that the file has the wrong endian order.  Tundra provides an endian conversion program to convert the endianness of files, if necessary.

After the first 32-bit integer, Spot files have another 32-bit integer of value 0x53504f54, which identifies the file as a Spot file.  If the integer value does not match, the Tundra program will report that the provided file is not a Spot file.

After the first two 32-bit integers, which form the signature of the file, Spot files have two more unsigned 32-bit integers, which form the header of the file.  The first of these header integers identifies the width of the image in pixels, and the second of these header integers identifies the height of the image in pixels.  Both values must be at least one.  Both values have a maximum of 32,767.

The complete header of a Spot image file is therefore:

1. Endian signature (0x72edf078)
2. Format signature (0x53504f54)
3. Width in pixels (1 to 32,767)
4. Height in pixels (1 to 32,767)

After the header, the rest of the file contains zero or more frames.  If the file contains zero frames, then there must be nothing in the file after the header.  If the file contains one frame, it immediately follows the header and there must be nothing after it.  If the file contains more than one frame, the first frame immediately follows the header and each subsequent frame immediately follows the frame that preceded it, with nothing after the last frame.  There must be no padding between scanlines, between frames, nor at the end of the file.

Each frame consists of one or more scanlines, with the total number of scanlines per frame equal to the height established in the header.  Scanlines are stored in top-to-bottom image order.  Each scanline consists of a sequence of one or more pixels, with the total number of pixels per scanline equal to the width established in the header.  Pixels are stored within scanlines in left-to-right image order.

Each pixel is an unsigned 32-bit integer.  The most significant byte of this integer is the alpha channel (0-255), below that is the red channel (0-255), below that is the green channel (0-255), and the least significant byte is the blue channel (0-255).  The order of the bytes will therefore be ARGB if the file is big endian, or BGRA if the file is little endian.

The alpha channel is interpreted as a linear value, where zero means fully transparent and 255 means fully opaque.  The RGB channels are non-premultiplied with respect to the alpha channel, so ARGB values of 128, 0, 255, 0 mean 50% transparent green, for example.

The RGB channels are interpreted according to the sRGB color space.  Each RGB channel is encoded in a non-linear range.  The following formula converts a linear component value in normalized floating-point range (0.0 to 1.0) to a non-linear component value in normalized floating-point range (0.0 to 1.0).  Multiplying the resultant V by 255, rounding to the nearest integer, and clamping the range to 0-255 will yield the non-linear component value that is stored in the Spot file:

```
V = (1.055 * L^(1/2.4)) - 0.055 if 0.0031308 <= L <= 1
V =  12.92 * L                  if 0.0031308 >  L >= 0
```

The inverse of the formula above is given below.  The inverse allows the non-linear RGB samples given in Spot files to be converted to linear samples.  However, the integer values in the Spot file (0-255) must first be converted to normalized floating-point range (0.0 to 1.0) by dividing the integer samples by 255.0.

```
L = ((V + 0.055) / 1.055) ^ 2.4 if 0.04045 <= L <= 1
L =   V / 12.92                 if 0.04045 >  L >= 0
```

In order to convert linear sRGB samples to XYZ samples in the 1931 CIE XYZ color space, the following formulas are used.  Note that the RGB values must be linear and in normalized floating-point range (0.0-1.0) before applying these formulas:

```
X = 0.4124 * R + 0.3576 * G + 0.1805 * B
Y = 0.2126 * R + 0.7152 * G + 0.0722 * B
Z = 0.0193 * R + 0.1192 * G + 0.9505 * B
```

The formula for Y given above can also be used to convert sRGB colors into grayscale.

In order to convert 1931 CIE XYZ samples to linear sRGB samples, the following formulas are used.  The XYZ samples are in normalized floating-point range (0.0-1.0), and the resulting RGB samples are linear, so the non-linear encoding described earlier will need to be applied and the result must be rounded to integer range 0-255 before storing the computed samples in a Spot file:

```
R =  3.2410 * X - 1.5374 * Y - 0.4986 * Z
G = -0.9692 * X + 1.8760 * Y + 0.0416 * Z
B =  0.0556 * X - 0.2040 * Y + 1.0570 * Z
```

Note that not all XYZ coordinates will result in a valid RGB combination, since the sRGB color space does not cover the entire XYZ gamut.

The linear sRGB color space is for all practical purposes the same as the linear ITU-R BT.709-6 ("Rec. 709") standard.  However, sRGB and Rec. 709 have different non-linear encoding systems for their component values.

It may be necessary to know the xy values of the Red, Green, and Blue primaries, as well as the xy values of the D65 illuminant used by sRGB, when working in color-managed workflows.  The following table gives the xyz values of Red, Green, Blue, and the D65 white point.  The z value can be computed from the xy values, so often only the xy values will be requested.  Note that xyz samples (lowercase xyz) are not the same as XYZ samples (uppercase XYZ):

Color       | x      | y      | z
------------|--------|--------|-------
Red         | 0.6400 | 0.3300 | 0.0300
Green       | 0.3000 | 0.6000 | 0.1000
Blue        | 0.1500 | 0.0600 | 0.7900
White (D65) | 0.3127 | 0.3290 | 0.3583
