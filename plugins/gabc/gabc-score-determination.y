%{
/*
Gregorio score determination in gabc input.
Copyright (C) 2006 Elie Roux <elie.roux@enst-bretagne.fr>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

/* 

This file is certainly not the most easy to understand, it is a bison file. See the bison manual on gnu.org for further details.

*/

#include "config.h"
#include <stdio.h>
#include <stdlib.h>
#include <gregorio/struct.h>
#include <gregorio/unicode.h>
#include <gregorio/messages.h>
#include <gregorio/characters.h>

#include "gabc.h"
#include "gabc-score-determination-l.h"
#include "gettext.h"

#define _(str) gettext(str)
#define N_(str) str
// request translation to the user native language for bison
#define YYENABLE_NLS 1


/*

we declare the type of gabc_score_determination_lval (in the flex file) to be char *.

*/

#define YYSTYPE char *
#define YYSTYPE_IS_DECLARED 1

// uncomment it if you want to have an interactive shell to understand the details on  how bison works for a certain input
//int gabc_score_determination_debug=1;

/*

We will need some variables and functions through the entire file, we declare them there:

*/

// the two functions to initialize and free the file variables
void initialize_variables ();
void free_variables ();
// the error string
char error[200];
// the score that we will determine and return
gregorio_score *score;
// an array of elements that we will use for each syllable
gregorio_element **elements;
// declaration of some functions, the first is the one initializing the flex/bison process
//int gabc_score_determination_parse ();
// other variables that we will have to use
gregorio_character *current_character;
gregorio_character *first_text_character;
gregorio_character *first_translation_character;
gregorio_voice_info *current_voice_info;
int number_of_voices;
int voice;
// can't remember what it is...
int clef;
// a char that will take some useful values see comments on text to understand it
char center_is_determined;
// current_key is... the current key... updated by each notes determination (for key changes)
int current_key = DEFAULT_KEY;

int check_score_integrity (gregorio_score * score);
void next_voice_info ();
void set_clef (char *str);
void reajust_voice_infos (gregorio_voice_info * voice_info, int final_count);
void end_definitions ();
void suppress_useless_styles ();
void close_syllable ();
void gregorio_gabc_add_text (char *mbcharacters);
void gregorio_gabc_add_style(unsigned char style);
void gregorio_gabc_end_style(unsigned char style);
void complete_with_nulls (int voice);

void gabc_score_determination_error(char *error_str) {
gregorio_message (error_str, (const char *)"gabc_score_determination_parse", ERROR, 0);
}


/* The "main" function. It is the function that is called when we have to read a gabc file. 
 * It takes a file descriptor, that is to say a file that is aleady open. 
 * It returns a valid gregorio_score
 */

gregorio_score *
read_score (FILE * f_in)
{
  // we initialize a file descriptor to /dev/null (see three lines below)
  FILE *f_out = fopen ("/dev/null", "w");
  // the input file that flex will parse
  gabc_score_determination_in = f_in;
  // the output file flex will write in (here /dev/null). We do not have to write in some file, we just have to build a score. Warnings and errors of flex are not written in this file, so they will appear anyway.
  gabc_score_determination_out = f_out;

  if (!f_in)
    {
      gregorio_message (_
			   ("can't read stream from argument, returning NULL pointer"),
			   "libgregorio_det_score", ERROR, 0);
      return NULL;
    }
  initialize_variables ();
  // the flex/bison main call, it will build the score (that we have initialized)
  gabc_score_determination_parse ();
  fclose (f_out);
  free_variables ();
  // the we check the validity and integrity of the score we have built.
  gregorio_fix_initial_keys (score, DEFAULT_KEY);
  if (!check_score_integrity (score))
    {
      gregorio_free_score (score);
      score = NULL;
      gregorio_message (_("unable to determine a valid score from file"),
			   "libgregorio_det_score", FATAL_ERROR, 0);
    }
  return score;
}

/* A function that checks to score integrity. For now it is... quite ridiculous... but it might be improved in the future.
 */

int
check_score_integrity (gregorio_score * score_to_check)
{
  if (!score_to_check)
    {
      return 0;
    }
  return 1;
}

/* 
 * Another function to be improved: this one checks the validity of the voice_infos.
 */

int
check_infos_integrity (gregorio_score * score_to_check)
{
  if (!score_to_check->name)
    {
      gregorio_message (_
			   ("no name specified, put `name:...;' at the beginning of the file, can be dangerous with some output formats"),
			   "libgregorio_det_score", WARNING, 0);
    }
  return 1;
}

/* The function that will initialize the variables.
 */

void
initialize_variables ()
{
  // build a brand new empty score
  score = gregorio_new_score ();
  // initialization of the first voice info to an empty voice info
  current_voice_info = NULL;
  gregorio_add_voice_info (&current_voice_info);
  score->first_voice_info = current_voice_info;
  // other initializations
  number_of_voices = 0;
  voice = 1;
  current_character = NULL;
  center_is_determined=0;
}


/* function that frees the variables that need it, for when we have finished to determine the score
 */

void
free_variables ()
{
  free (elements);
}

// a macro to put inside a if to see if a voice_info is empty
#define voice_info_is_not_empty(voice_info)   voice_info->initial_key!=5 || voice_info->anotation || voice_info->author || voice_info->date || voice_info->manuscript || voice_info->reference || voice_info->storage_place || voice_info->translator || voice_info->translation_date || voice_info->style || voice_info->virgula_position


/* a function called when we see "--\n" that end the infos for a certain voice
 */
void
next_voice_info ()
{
  //we must do this test in the case where there would be a "--" before first_declarations
  if (voice_info_is_not_empty (current_voice_info))
    {
      gregorio_add_voice_info (&current_voice_info);
      voice++;
    }
}

/* Function that updates the clef variable, intepreting the char *str argument
 */
void
set_clef (char *str)
{
  if (!str || !str[0] || !str[1])
    {
      gregorio_message (_
			   ("unknown clef format in initial-key definition : format is `(c|f)[1-4]'"),
			   "libgregorio_det_score", ERROR, 0);
    }
  if (str[0] != 'c' && str[0] != 'f')
    {
      gregorio_message (_
			   ("unknown clef format in initial-key definition : format is `(c|f)[1-4]'"),
			   "libgregorio_det_score", ERROR, 0);
      return;
    }
//here is something than could be changed : the format of the inital_key attribute
  if (str[1] != '1' && str[1] != '2' && str[1] != '3' && str[1] != '4')
    {
      gregorio_message (_
			   ("unknown clef format in initial-key definition : format is `(c|f)[1-4]'"),
			   "libgregorio_det_score", ERROR, 0);
      return;
    }

  clef = gregorio_calculate_new_key (str[0], str[1] - 48);
  if (str[2])
    {
      gregorio_message (_
			   ("in initial_key definition, only two characters are needed : format is`(c|f)[1-4]'"),
			   "libgregorio_det_score", WARNING, 0);
    }
  current_key = clef;
}

/* Function that frees the voice_infos for voices > final_count. Useful if there are too many voice_infos
 */

void
reajust_voice_infos (gregorio_voice_info * voice_info, int final_count)
{
  int i = 1;
  while (voice_info && i <= final_count)
    {
      voice_info = voice_info->next_voice_info;
    }
  gregorio_free_voice_infos (voice_info);
}

/* Function called when we have reached the end of the definitions, it tries to make the voice_infos coherent.
 */
void
end_definitions ()
{
  int i;

  if (!check_infos_integrity (score))
    {
      gregorio_message (_("can't determine valid infos on the score"),
			   "libgregorio_det_score", ERROR, 0);
    }
  if (!number_of_voices)
    {
      if (voice > MAX_NUMBER_OF_VOICES)
	{
	  voice = MAX_NUMBER_OF_VOICES;
	  reajust_voice_infos (score->first_voice_info, number_of_voices);
	}
      number_of_voices = voice;
      score->number_of_voices = voice;
    }
  else
    {
      if (number_of_voices > voice)
	{
	  snprintf (error, 62,
		    ngettext
		    ("not enough voice infos found: %d found, %d waited, %d assumed",
		     "not enough voice infos found: %d found, %d waited, %d assumed",
		     voice), voice, number_of_voices, voice);
	  gregorio_message (error, "libgregorio_det_score", WARNING, 0);
	  score->number_of_voices = voice;
	  number_of_voices = voice;
	}
      else
	{
	  if (number_of_voices < voice)
	    {
	      snprintf (error, 62,
			ngettext
			("too many voice infos found: %d found, %d waited, %d assumed",
			 "not enough voice infos found: %d found, %d waited, %d assumed",
			 number_of_voices), voice, number_of_voices,
			number_of_voices);
	      gregorio_message (error, "libgregorio_det_score", WARNING,
				   0);
	    }
	}
    }
  voice = 0;			// voice is now voice-1, so that it can be the index of elements 
  elements =
    (gregorio_element **) malloc (number_of_voices *
				  sizeof (gregorio_element *));
  for (i = 0; i < number_of_voices; i++)
    {
      elements[i] = NULL;
    }
}

/* Here starts the code for the determinations of the notes. The notes are not precisely determined here, we separate the text describing the notes of each voice, and we call determine_elements_from_string to really determine them.
 */
char *current_text = NULL; // TODO : not sure of the =NULL
char position = WORD_BEGINNING;
gregorio_syllable *current_syllable = NULL;


/* Function called when we see a ")", it completes the gregorio_element array of the syllable with NULL pointers. Usefull in the cases where for example you have two voices, but a voice that is silent on a certain syllable.
 */
void
complete_with_nulls (int last_voice)
{
  int i;
  for (i = last_voice + 1; i < number_of_voices; i++)
    {
      elements[i] = NULL;
    }
}

/* Function called each time we find a space, it updates the current position.
 */
void
update_position_with_space ()
{
  if (position == WORD_MIDDLE)
    {
      position = WORD_END;
    }
  if (position == WORD_BEGINNING)
    {
      position = WORD_ONE_SYLLABLE;
    }
}

/* Function to close a syllable and update the position.
 */

void
close_syllable ()
{
  // we rebuild the first syllable text if it is the first syllable, or if it is the second when the first has no text.
  // it is a patch for cases like (c4) Al(ab)le(ab)
  if ((!score -> first_syllable && score->initial_style != NO_INITIAL && first_text_character)
       || (current_syllable && !current_syllable->previous_syllable && !current_syllable->text && first_text_character))
    {
       gregorio_rebuild_first_syllable (&first_text_character);
    }
  gregorio_add_syllable (&current_syllable, number_of_voices, elements,
			    first_text_character, first_translation_character, position);
  if (!score->first_syllable)
    {
    // we rebuild the first syllable if we have to
      score->first_syllable = current_syllable;
    }
  //we update the position
  if (position == WORD_BEGINNING)
    {
      position = WORD_MIDDLE;
    }
  if (position == WORD_ONE_SYLLABLE || position == WORD_END)
    {
      position = WORD_BEGINNING;
    }
  center_is_determined=CENTER_NOT_DETERMINED;
  current_character = NULL;
  first_text_character=NULL;
  first_translation_character=NULL;
}

// a function called when we see a [, basically, all characters are added to the translation pointer instead of the text pointer
void start_translation() {
  gregorio_rebuild_characters (&current_character, center_is_determined);
  first_text_character = current_character;
  center_is_determined=CENTER_FULLY_DETERMINED; // the middle letters of the translation have no sense
  current_character=NULL;
}

void end_translation() {
  gregorio_rebuild_characters (&current_character, center_is_determined);
  first_translation_character=current_character;
}

void
test ()
{

}

/*

gregorio_gabc_add_text is the function called when lex returns a char *. In this function we convert it into grewchar, and then we add the corresponding gregorio_characters in the list of gregorio_characters.

*/

void
gregorio_gabc_add_text (char *mbcharacters)
{
  if (current_character)
    {
      current_character->next_character = gregorio_build_char_list_from_buf (mbcharacters);
      current_character->next_character->previous_character = current_character;
    }
  else
    {
      current_character = gregorio_build_char_list_from_buf (mbcharacters);
    }
  while (current_character -> next_character)
    {
      current_character = current_character -> next_character;
    }
}

/*

The two functions called when lex returns a style, we simply add it. All the complex things will be done by the function after...

*/

void
gregorio_gabc_add_style(unsigned char style) 
{
  gregorio_begin_style(&current_character, style);
}

void
gregorio_gabc_end_style(unsigned char style) 
{
  gregorio_end_style(&current_character, style);
}

%}

%token ATTRIBUTE COLON SEMICOLON OFFICE_PART ANOTATION AUTHOR DATE MANUSCRIPT REFERENCE STORAGE_PLACE TRANSLATOR TRANSLATION_DATE STYLE VIRGULA_POSITION LILYPOND_PREAMBLE OPUSTEX_PREAMBLE MUSIXTEX_PREAMBLE INITIAL_STYLE MODE GREGORIOTEX_FONT SOFTWARE_USED NAME OPENING_BRACKET NOTES VOICE_CUT CLOSING_BRACKET NUMBER_OF_VOICES INITIAL_KEY VOICE_CHANGE END_OF_DEFINITIONS SPACE CHARACTERS I_BEGINNING I_END TT_BEGINNING TT_END B_BEGINNING B_END SC_BEGINNING SC_END SP_BEGINNING SP_END VERB_BEGINNING VERB VERB_END CENTER_BEGINNING CENTER_END CLOSING_BRACKET_WITH_SPACE TRANSLATION_BEGINNING TRANSLATION_END

%%

score:
	all_definitions syllables
	;

all_definitions:
	definitions END_OF_DEFINITIONS {
	end_definitions();
	}
	;

definitions:
	| definitions definition
	;

number_of_voices_definition:
	NUMBER_OF_VOICES attribute {
	number_of_voices=atoi($2);
	if (number_of_voices > MAX_NUMBER_OF_VOICES) {
	snprintf(error, 40, _("can't define %d voices, maximum is %d"), number_of_voices, MAX_NUMBER_OF_VOICES);
	gregorio_message(error,"libgregorio_det_score",WARNING,0);
	}
	gregorio_set_score_number_of_voices (score, number_of_voices);
	}

name_definition:
	NAME attribute {
	if ($2==NULL) {
	gregorio_message("name can't be empty","libgregorio_det_score", WARNING, 0);
	}
	if (score->name) {
	gregorio_message(_("several name definitions found, only the last will be taken into consideration"), "libgregorio_det_score",WARNING, 0);
	}
	gregorio_set_score_name (score, $2);
	}
	;

lilypond_preamble_definition:
	LILYPOND_PREAMBLE attribute {
	if (score->lilypond_preamble) {
	gregorio_message(_("several lilypond preamble definitions found, only the last will be taken into consideration"), "libgregorio_det_score",WARNING,0);
	}
	gregorio_set_score_lilypond_preamble (score, $2);
	}
	;

opustex_preamble_definition:
	OPUSTEX_PREAMBLE attribute {
	if (score->opustex_preamble) {
	gregorio_message(_("several OpusTeX preamble definitions found, only the last will be taken into consideration"), "libgregorio_det_score",WARNING,0);
	}
	gregorio_set_score_opustex_preamble (score, $2);
	}
	;

musixtex_preamble_definition:
	MUSIXTEX_PREAMBLE attribute {
	if (score->musixtex_preamble) {
	gregorio_message(_("several MusiXTeX preamble definitions found, only the last will be taken into consideration"), "libgregorio_det_score",WARNING,0);
	}
	gregorio_set_score_musixtex_preamble (score, $2);
	}
	;

gregoriotex_font_definition:
	GREGORIOTEX_FONT attribute {
	if (score->gregoriotex_font) {
	gregorio_message(_("several GregorioTeX font definitions found, only the last will be taken into consideration"), "libgregorio_det_score",WARNING,0);
	}
	score->gregoriotex_font=$2;
	}
	;

office_part_definition:
	OFFICE_PART attribute {
	if (score->office_part) {
	gregorio_message(_("several office part definitions found, only the last will be taken into consideration"), "libgregorio_det_score",WARNING,0);
	}
	gregorio_set_score_office_part (score, $2);
	}
	;

mode_definition:
	MODE attribute {
	if (score->mode) {
	gregorio_message(_("several mode definitions found, only the last will be taken into consideration"), "libgregorio_det_score",WARNING,0);
	}
	if ($2)
	  {
	    score->mode=atoi($2);
	    free($2);
	  }
	}
	;

initial_style_definition:
	INITIAL_STYLE attribute {
	if ($2)
	  {
	    score->initial_style=atoi($2);
	    free($2);
	  }
	}
	;

initial_key_definition:
	INITIAL_KEY attribute {
	if (current_voice_info->initial_key!=NO_KEY) {
	snprintf(error,99,_("several definitions of initial key found for voice %d, only the last will be taken into consideration"),voice);
	gregorio_message(error, "libgregorio_det_score",WARNING,0);
	}
	set_clef($2);
	gregorio_set_voice_initial_key (current_voice_info, clef);
	}
	;

anotation_definition:
	ANOTATION attribute {
	if (current_voice_info->anotation) {
	snprintf(error,99,_("several definitions of anotation found for voice %d, only the last will be taken into consideration"),voice);
	gregorio_message(error, "libgregorio_det_score",WARNING,0);
	}
	gregorio_set_voice_anotation (current_voice_info, $2);
	}
	;

author_definition:
	AUTHOR attribute {
	if (current_voice_info->author) {
	snprintf(error,99,_("several definitions of author found for voice %d, only the last will be taken into consideration"),voice);
	gregorio_message(error, "libgregorio_det_score",WARNING,0);
	}
	gregorio_set_voice_author (current_voice_info, $2);
	}
	;

date_definition:
	DATE attribute {
	if (current_voice_info->date) {
	snprintf(error,99,_("several definitions of date found for voice %d, only the last will be taken into consideration"),voice);
	gregorio_message(error, "libgregorio_det_score",WARNING,0);
	}
	gregorio_set_voice_date (current_voice_info, $2);
	}
	;

manuscript_definition:
	MANUSCRIPT attribute {
	if (current_voice_info->manuscript) {
	snprintf(error,99,_("several definitions of manuscript found for voice %d, only the last will be taken into consideration"),voice);
	gregorio_message(error, "libgregorio_det_score",WARNING,0);
	}
	gregorio_set_voice_manuscript (current_voice_info, $2);
	}
	;

reference_definition:
	REFERENCE attribute {
	if (current_voice_info->reference) {
	snprintf(error,99,_("several definitions of reference found for voice %d, only the last will be taken into consideration"),voice);
	gregorio_message(error, "libgregorio_det_score",WARNING,0);
	}
	gregorio_set_voice_reference (current_voice_info, $2);
	}
	;

storage_place_definition:
	STORAGE_PLACE attribute {
	if (current_voice_info->storage_place) {
	snprintf(error,105,_("several definitions of storage place found for voice %d, only the last will be taken into consideration"),voice);
	gregorio_message(error, "libgregorio_det_score",WARNING,0);
	}
	gregorio_set_voice_storage_place (current_voice_info, $2);
	}
	;

translator_definition:
	TRANSLATOR attribute {
	if (current_voice_info->translator) {
	snprintf(error,99,_("several definitions of translator found for voice %d, only the last will be taken into consideration"),voice);
	gregorio_message(error, "libgregorio_det_score",WARNING,0);
	}
	gregorio_set_voice_translator (current_voice_info, $2);
	//free($2);
	}
	;

translation_date_definition:
	TRANSLATION_DATE attribute {
	if (current_voice_info->translation_date) {
	snprintf(error,105,_("several definitions of translation date found for voice %d, only the last will be taken into consideration"),voice);
	gregorio_message(error, "libgregorio_det_score",WARNING,0);
	}
	gregorio_set_voice_translation_date (current_voice_info, $2);
	}
	;

style_definition:
	STYLE attribute {
	if (current_voice_info->style) {
	snprintf(error,99,_("several definitions of style found for voice %d, only the last will be taken into consideration"),voice);
	gregorio_message(error, "libgregorio_det_score",WARNING,0);
	}
	gregorio_set_voice_style (current_voice_info, $2);
	}
	;

virgula_position_definition:
	VIRGULA_POSITION attribute {
	if (current_voice_info->virgula_position) {
	snprintf(error,105,_("several definitions of virgula position found for voice %d, only the last will be taken into consideration"),voice);
	gregorio_message(error, "libgregorio_det_score",WARNING,0);
	}
	gregorio_set_voice_virgula_position (current_voice_info, $2);
	}
	;


sotfware_used_definition:
	SOFTWARE_USED attribute {
	//libgregorio_set_voice_sotfware_used (current_voice_info, $2);
	}
	;

attribute:
	COLON ATTRIBUTE SEMICOLON {
	$$=$2;
	}
	|
	COLON SEMICOLON {
	$$=NULL;
	}
	;

definition:
	number_of_voices_definition
	|
	name_definition
	|
	initial_key_definition
	|
	sotfware_used_definition
	|
	musixtex_preamble_definition
	|
	opustex_preamble_definition
	|
	lilypond_preamble_definition
	|
	virgula_position_definition
	|
	style_definition
	|
	translation_date_definition
	|
	translator_definition
	|
	storage_place_definition
	|
	reference_definition
	|
	manuscript_definition
	|
	date_definition
	|
	author_definition
	|
	anotation_definition
	|
	office_part_definition
	|
	initial_style_definition
	|
	mode_definition
	|
	gregoriotex_font_definition
	|
	VOICE_CHANGE {
	next_voice_info ();
	}
	;

notes:
	|notes note
	;

note:
	NOTES CLOSING_BRACKET {
	if (voice<number_of_voices) {
	elements[voice]=libgregorio_gabc_det_elements_from_string($1, &current_key);
	free($1);
	}
	else {
	snprintf(error,105,ngettext("too many voices in note : %d foud, %d expected","too many voices in note : %d foud, %d expected",number_of_voices),voice+1, number_of_voices);
	gregorio_message(error, "libgregorio_det_score",ERROR,0);
	}
	if (voice<number_of_voices-1) {
	snprintf(error,105,ngettext("not enough voices in note : %d foud, %d expected, completing with empty neume","not enough voices in note : %d foud, %d expected, completing with empty neume",voice+1),voice+1, number_of_voices);
	gregorio_message(error, "libgregorio_det_score",VERBOSE,0);
	complete_with_nulls(voice);
	}
	voice=0;
	}
	|
	NOTES CLOSING_BRACKET_WITH_SPACE {
	if (voice<number_of_voices) {
	elements[voice]=libgregorio_gabc_det_elements_from_string($1, &current_key);
	free($1);
	}
	else {
	snprintf(error,105,ngettext("too many voices in note : %d foud, %d expected","too many voices in note : %d foud, %d expected",number_of_voices),voice+1, number_of_voices);
	gregorio_message(error, "libgregorio_det_score",ERROR,0);
	}
	if (voice<number_of_voices-1) {
	snprintf(error,105,ngettext("not enough voices in note : %d foud, %d expected, completing with empty neume","not enough voices in note : %d foud, %d expected, completing with empty neume",voice+1),voice+1, number_of_voices);
	gregorio_message(error, "libgregorio_det_score",VERBOSE,0);
	complete_with_nulls(voice);
	}
	voice=0;
	update_position_with_space();
	}
	|
	NOTES VOICE_CUT{
	if (voice<number_of_voices) {
	elements[voice]=libgregorio_gabc_det_elements_from_string($1, &current_key);
	free($1);
	voice++;
	}
	else {
	snprintf(error,105,ngettext("too many voices in note : %d found, %d expected","too many voices in note : %d foud, %d expected",number_of_voices),voice+1, number_of_voices);
	gregorio_message(error, "libgregorio_det_score",ERROR,0);
	}
	}
	|
	CLOSING_BRACKET {
	elements[voice]=NULL;
	voice=0;
	}
	|
	CLOSING_BRACKET_WITH_SPACE {
	elements[voice]=NULL;
	voice=0;
	update_position_with_space();
	}
	;

style_beginning:
	I_BEGINNING {
	gregorio_gabc_add_style(ST_ITALIC);
	}
	|
	TT_BEGINNING {
	gregorio_gabc_add_style(ST_TT);
	}
	|
	B_BEGINNING {
	gregorio_gabc_add_style(ST_BOLD);
	}
	|
	SC_BEGINNING {
	gregorio_gabc_add_style(ST_SMALL_CAPS);
	}
	|
	VERB_BEGINNING {
	gregorio_gabc_add_style(ST_VERBATIM);
	}
	|
	SP_BEGINNING {
	gregorio_gabc_add_style(ST_SPECIAL_CHAR);
	}
	|
	CENTER_BEGINNING {if (!center_is_determined) {
	gregorio_gabc_add_style(ST_FORCED_CENTER);
	center_is_determined=CENTER_HALF_DETERMINED;
	}
	}
	;
	
style_end:
	I_END {
	gregorio_gabc_end_style(ST_ITALIC);
	}
	|
	TT_END {
	gregorio_gabc_end_style(ST_TT);
	}
	|
	B_END {
	gregorio_gabc_end_style(ST_BOLD);
	}
	|
	SC_END {
	gregorio_gabc_end_style(ST_SMALL_CAPS);
	}
	|
	VERB_END {
	gregorio_gabc_end_style(ST_VERBATIM);
	}
	|
	SP_END {
	gregorio_gabc_end_style(ST_SPECIAL_CHAR);
	}
	|
	CENTER_END {
	if (center_is_determined==CENTER_HALF_DETERMINED) {
	  gregorio_gabc_end_style(ST_FORCED_CENTER);
	  center_is_determined=CENTER_FULLY_DETERMINED;
	}
	}
	;

character:
	CHARACTERS {
	gregorio_gabc_add_text($1);
	}
	|
	style_beginning
	|
	style_end
	;
	
text:
	|text character
	;

translation_beginning:
    TRANSLATION_BEGINNING {
    start_translation();
    }
    ;

translation:
    translation_beginning text TRANSLATION_END {
    end_translation();
    }
    ;

syllable_with_notes:
	text OPENING_BRACKET notes {
	gregorio_rebuild_characters (&current_character, center_is_determined);
    first_text_character = current_character;
	close_syllable();
	}
	|
	text translation OPENING_BRACKET notes {
	close_syllable();
	}
	;

notes_without_word:
	OPENING_BRACKET notes {
	close_syllable();
	}
	|
	translation OPENING_BRACKET notes {
	close_syllable();
	}
	;

syllable:
	syllable_with_notes
	|
	notes_without_word
	;

syllables:
	|syllables syllable
	;
