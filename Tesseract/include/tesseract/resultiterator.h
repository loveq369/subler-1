///////////////////////////////////////////////////////////////////////
// File:        resultiterator.h
// Description: Iterator for tesseract results that avoids using tesseract
//              internal data structures.
// Author:      Ray Smith
// Created:     Fri Feb 26 11:01:06 PST 2010
//
// (C) Copyright 2010, Google Inc.
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
///////////////////////////////////////////////////////////////////////

#ifndef TESSERACT_API_RESULTITERATOR_H__
#define TESSERACT_API_RESULTITERATOR_H__

#include "pageiterator.h"

class BLOB_CHOICE_IT;

namespace tesseract {

class Tesseract;

// Class to iterate over tesseract results, providing access to all levels
// of the page hierarchy, without including any tesseract headers or having
// to handle any tesseract structures.
// WARNING! This class points to data held within the TessBaseAPI class, and
// therefore can only be used while the TessBaseAPI class still exists and
// has not been subjected to a call of Init, SetImage, Recognize, Clear, End
// DetectOS, or anything else that changes the internal PAGE_RES.
// See apitypes.h for the definition of PageIteratorLevel.
// See also base class PageIterator, which contains the bulk of the interface.
// ResultIterator adds text-specific methods for access to OCR output.

class ResultIterator : public PageIterator {
  friend class ChoiceIterator;
 public:
  // page_res and tesseract come directly from the BaseAPI.
  // The rectangle parameters are copied indirectly from the Thresholder,
  // via the BaseAPI. They represent the coordinates of some rectangle in an
  // original image (in top-left-origin coordinates) and therefore the top-left
  // needs to be added to any output boxes in order to specify coordinates
  // in the original image. See TessBaseAPI::SetRectangle.
  // The scale and scaled_yres are in case the Thresholder scaled the image
  // rectangle prior to thresholding. Any coordinates in tesseract's image
  // must be divided by scale before adding (rect_left, rect_top).
  // The scaled_yres indicates the effective resolution of the binary image
  // that tesseract has been given by the Thresholder.
  // After the constructor, Begin has already been called.
  ResultIterator(PAGE_RES* page_res, Tesseract* tesseract,
                 int scale, int scaled_yres,
                 int rect_left, int rect_top,
                 int rect_width, int rect_height);
  virtual ~ResultIterator();

  // ResultIterators may be copied! This makes it possible to iterate over
  // all the objects at a lower level, while maintaining an iterator to
  // objects at a higher level. These constructors DO NOT CALL Begin, so
  // iterations will continue from the location of src.
  // TODO: For now the copy constructor and operator= only need the base class
  // versions, but if new data members are added, don't forget to add them!

  // ============= Moving around within the page ============.

  // See PageIterator.

  // ============= Accessing data ==============.

  // Returns the null terminated UTF-8 encoded text string for the current
  // object at the given level. Use delete [] to free after use.
  char* GetUTF8Text(PageIteratorLevel level) const;

  // Returns the mean confidence of the current object at the given level.
  // The number should be interpreted as a percent probability. (0.0f-100.0f)
  float Confidence(PageIteratorLevel level) const;

  // ============= Functions that refer to words only ============.

  // Returns the font attributes of the current word. If iterating at a higher
  // level object than words, eg textlines, then this will return the
  // attributes of the first word in that textline.
  // The actual return value is a string representing a font name. It points
  // to an internal table and SHOULD NOT BE DELETED. Lifespan is the same as
  // the iterator itself, ie rendered invalid by various members of
  // TessBaseAPI, including Init, SetImage, End or deleting the TessBaseAPI.
  // Pointsize is returned in printers points (1/72 inch.)
  const char* WordFontAttributes(bool* is_bold,
                                 bool* is_italic,
                                 bool* is_underlined,
                                 bool* is_monospace,
                                 bool* is_serif,
                                 bool* is_smallcaps,
                                 int* pointsize,
                                 int* font_id) const;

  // Returns true if the current word was found in a dictionary.
  bool WordIsFromDictionary() const;

  // Returns true if the current word is numeric.
  bool WordIsNumeric() const;

  // ============= Functions that refer to symbols only ============.

  // Returns true if the current symbol is a superscript.
  // If iterating at a higher level object than symbols, eg words, then
  // this will return the attributes of the first symbol in that word.
  bool SymbolIsSuperscript() const;
  // Returns true if the current symbol is a subscript.
  // If iterating at a higher level object than symbols, eg words, then
  // this will return the attributes of the first symbol in that word.
  bool SymbolIsSubscript() const;
  // Returns true if the current symbol is a dropcap.
  // If iterating at a higher level object than symbols, eg words, then
  // this will return the attributes of the first symbol in that word.
  bool SymbolIsDropcap() const;
};

// Class to iterate over the classifier choices for a single RIL_SYMBOL.
class ChoiceIterator {
 public:
  // Construction is from a ResultIterator that points to the symbol of
  // interest. The ChoiceIterator allows a one-shot iteration over the
  // choices for this symbol and after that is is useless.
  explicit ChoiceIterator(const ResultIterator& result_it);
  ~ChoiceIterator();

  // Moves to the next choice for the symbol and returns false if there
  // are none left.
  bool Next();

  // ============= Accessing data ==============.

  // Returns the null terminated UTF-8 encoded text string for the current
  // choice.
  // NOTE: Unlike ResultIterator::GetUTF8Text, the return points to an
  // internal structure and should NOT be delete[]ed to free after use.
  const char* GetUTF8Text() const;

  // Returns the confidence of the current choice.
  // The number should be interpreted as a percent probability. (0.0f-100.0f)
  float Confidence() const;

 private:
  // Pointer to the Tesseract object owned by the API.
  Tesseract* tesseract_;
  // Iterator over the blob choices.
  BLOB_CHOICE_IT* choice_it_;
};

}  // namespace tesseract.

#endif  // TESSERACT_API_RESULT_ITERATOR_H__
