#import <Foundation/Foundation.h>

/// Writes the artwork of the current Now Playing item to standard output, as
/// the image file the player published (JPEG or PNG), or nothing if there is
/// none. The two arguments are the ones Perl hands an XSUB and are ignored.
void NPMWriteArtwork(void *interpreter, void *cv);
