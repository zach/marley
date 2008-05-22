#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// when DUMP is defined, the program outputs directly from the parser
// #define DUMP

#define MAX_FN_NAME_LEN 31
#define MAX_TOTAL_PARAM_LEN 1500*1024
#define MAX_PARAMS 32*1024
#define READ_BUF_SIZE 2*MAX_TOTAL_PARAM_LEN

#define MAX_NODE_NAME_PATH_LEN 4096
#define MAX_NODE_NAME_LEN 255 // anything beyond this length is truncated
#define MAX_NODE_TYPE_LEN 31
#define MAX_NODES 1024*1024

// currently-parsed function name and parameters
char function_name[MAX_FN_NAME_LEN+1];
int numFunctionParams;
char *functionParams[MAX_PARAMS];

// nodes created in the .ma file
struct MANode {
	char name[MAX_NODE_NAME_LEN];
	char type[MAX_NODE_TYPE_LEN];
	struct MANode *child; // first child
	struct MANode *parent;
	struct MANode *nextSibling;
} nodes[MAX_NODES], rootNode = {
	"",
	"",
	NULL, NULL, NULL
};
int numNodes;

// data area used while reading function parameters
char functionParamPool[MAX_TOTAL_PARAM_LEN+1];
char *functionParamPoolPtr = functionParamPool;

// string markers used during parsing
char *function_name_mark;
char *function_param_mark;

static void parseFile(FILE *inputFile);
static void outputNode(struct MANode *node);
static struct MANode *createNode(const char *type, const char *name, const char *parentName);
static void attachNode(struct MANode *node, struct MANode *parent);
static char *flagArgument(const char *shortFlagName, const char *longFlagName);
static char *unquote(char *quotedString);

// Ragel data variables
size_t cs;
char *p;
char *pe;

%%{
	machine ma;

	action onFunctionNameStart {
		function_name_mark = p;
	}
	action onFunctionName {
		size_t len = (p - function_name_mark) / sizeof(char);

		if (len > MAX_FN_NAME_LEN){
			char *fullName = malloc(len+1);
			strncpy(fullName, function_name_mark, len);
			fullName[len] = '\0';
			fprintf(stderr, "Warning: function name %s exceeds program limits.\n", fullName);
			free(fullName);
			len = MAX_FN_NAME_LEN;
		}
			
		strncpy(function_name, function_name_mark, len);
		function_name[len] = '\0';
	}

	action onArgumentStart {
		function_param_mark = p;
	}
	action onArgument {
		if (numFunctionParams == MAX_PARAMS){
			fprintf(stderr, "Warning: total number of parameters for function %s exceeds program limits.\n", function_name);
		} else {
			size_t len = (p - function_param_mark) / sizeof(char);

			if ((functionParamPoolPtr + len + 1) - functionParamPoolPtr > MAX_TOTAL_PARAM_LEN+1){
				fprintf(stderr, "Warning: length of parameter #%d for function %s exceeds program limits.\n", numFunctionParams+1, function_name);
				len = 0;
			}

			// copy the data into the parameter pool and keep a pointer to it
			functionParams[numFunctionParams] = functionParamPoolPtr;
			strncpy(functionParamPoolPtr, function_param_mark, len);
			functionParamPoolPtr[len] = '\0';
			functionParamPoolPtr += len + 1;
			numFunctionParams++;		
		}
	}

	action onFunction {
#ifdef DUMP
		int i;

		printf("%s", function_name);
		for(i=0; i < numFunctionParams; i++)
			printf("\t%s", functionParams[i]);
#else
		if (strcmp(function_name, "createNode") == 0)
			createNode(functionParams[0], unquote(flagArgument("-name", "-n")), unquote(flagArgument("-parent", "-p")));
#endif
		numFunctionParams = 0;
		functionParamPoolPtr = functionParamPool;
	}

	initial_identifier_char = alpha | '_';
	identifier_char = alnum | '_';
	identifier = initial_identifier_char . identifier_char*;
	
	flag = '-' . identifier;
	symbol = ':' . identifier;

	string_char = [^"\\] | /\\./; # match any non-quote or any escaped character
	simple_string = '"' . string_char* . '"';
	string = simple_string . (space* . '+' . space* . simple_string)*; # allow string addition

	int	= '-'? . digit+;
	float = ('+' | '-')? . digit* . '.' . digit+ . (('E' | 'e') . ('+' | '-')? . digit+)?;
	numeral = int | float;

	simple_argument = (string | flag | symbol | numeral | identifier);
	argument = ('(' . space* . simple_argument . space* . ')') | simple_argument;

	function = identifier >onFunctionNameStart %onFunctionName . ( space+ . argument >onArgumentStart %onArgument )* . space* . ';' @onFunction;

	comment = '//' [^\n]* '\n'; # consume C++/C99 comments

	main := (function | comment | space)*;
}%%


%% write data;


int main(int argc, char *argv[])
{
	if (argc == 1) {
		printf("Usage: %s\n", argv[0]);
	} else {
		// use stdin if "-" supplied as filename
		FILE *inputFile = (strcmp(argv[1], "-") == 0) ? stdin : fopen(argv[1], "r");

		%% write init;

		parseFile(inputFile);

		if (inputFile != stdin)
			fclose(inputFile);
	}

#ifndef DUMP
	outputNode(&rootNode);
#endif

	return 0;
}


// Uses input strategy from section 5.9 of Ragel user guide -
// reverse-scan input buffer for a known separator and use that to chunk
void parseFile(FILE *inputFile)
{
	static char buf[READ_BUF_SIZE];
	char *bufReadStart = buf;

	// read file in chunks
	for (;;) {
		char *dataEnd;
		size_t maxReadSize = READ_BUF_SIZE - (size_t)(bufReadStart - buf);
		size_t dataLength = fread(buf, 1, maxReadSize, inputFile);

		if (dataLength == 0 && bufReadStart == buf) // if there's no data from the file and nothing left to parse, we're done
			return;

		// set dataEnd just past a splitting point -- look for a semicolon (followed by a newline, just to be safe)
		if (dataLength == maxReadSize && dataLength > 1) {
			char *pc;

			for(pc = bufReadStart + dataLength - 2; pc != buf; pc--) {
				if (pc[0] == ';' && pc[1] == '\n') {
					dataEnd = pc + 2; // include both of those characters
					break;
				}
			}

			if (pc == buf)
				dataEnd = bufReadStart + dataLength; // cool, we must be on the last line
		} else {
			dataEnd = bufReadStart + dataLength;
		}

		p = buf;
		pe = dataEnd;

		%% write exec;

		// move anything from dataEnd to the end of the buffer into the beginning
		if (dataEnd != bufReadStart + dataLength) {
			size_t remainder = READ_BUF_SIZE - (size_t)(dataEnd - buf);
			memmove(buf, dataEnd, remainder);
			bufReadStart = buf + remainder;
		} else {
			bufReadStart = buf;
		}
	}
}

void outputNode(struct MANode *node)
{
	static char path[MAX_NODE_NAME_PATH_LEN];
	char *endOfParentPath;

	if (!node)
		return;

	if (node == &rootNode) {
		*path = '\0';
		endOfParentPath = path;
	} else {
		endOfParentPath = path + strlen(path);

		strcat(path, "/");
		strcat(path, node->name);

		printf("%s:%s\n", node->type, path);
	}

	// go depth-first
	if (node->child)
		outputNode(node->child);

	*endOfParentPath = '\0'; // reset path
	if (node->nextSibling)
		outputNode(node->nextSibling);
}

struct MANode *createNode(const char *nodeType, const char *nodeName, const char *parentNodeName)
{
	struct MANode *node = nodes + numNodes;
	struct MANode *parentNode = &rootNode;

	// copy name and type to node

	if (nodeName) {
		strncpy(node->name, nodeName, MAX_NODE_NAME_LEN);
		node->name[MAX_NODE_NAME_LEN] = '\0';
	} else {
		node->name[0] = '\0';
	}

	strncpy(node->type, nodeType, MAX_NODE_TYPE_LEN);
	node->type[MAX_NODE_TYPE_LEN] = '\0';

	if (parentNodeName) {
		int i;

		for (i=0; i < numNodes; i++) {
			if (strncmp(nodes[i].name, parentNodeName, MAX_NODE_NAME_LEN) == 0) {
				parentNode = nodes + i;
				break;
			}
		}

		if (i == numNodes)
			fprintf(stderr, "Cannot find parent %s for node %s\n", parentNodeName, nodeName);
	}

	attachNode(node, parentNode);

	numNodes++;

	return node;
}

void attachNode(struct MANode *node, struct MANode *parent)
{
	node->parent = parent;

	if (parent->child) { // attach on end of parent's sibling chain
		struct MANode *lastChild = parent->child;
		while (lastChild->nextSibling)
			lastChild = lastChild->nextSibling;
		lastChild->nextSibling = node;
	} else {
		parent->child = node;
	}

	node->nextSibling = NULL;
}

// look for presence of either flag in current function params and return following argument
char *flagArgument(const char *shortFlagName, const char *longFlagName)
{
	int i;

	for (i=0; i < numFunctionParams-1; i++) {
		if ((shortFlagName && strcmp(functionParams[i], shortFlagName) == 0) ||
		    (longFlagName && strcmp(functionParams[i], longFlagName) == 0))
			return functionParams[i+1];
	}
	
	return NULL;
}

// unquote() converts in-place a string inside double quotes and
// containing escaped characters to the literal string it specifies.
// This function also allows for string addition since it skips over
// text which is not inside double quotes.
char *unquote(char *quotedString)
{
	char *start = quotedString;
	char *s = quotedString;
	char *d = quotedString;

	if (!quotedString || (*quotedString != '"' && *quotedString != '('))
		return quotedString;

	while (*s != '\0') {
		if (*s++ == '"') { // skip characters until opening quote
			while (*s != '"' && *s != '\0') { // read until closing quote
				if (*s == '\\') {
					if (s[1] == 'n')
						*d++ = '\n';
					else if (s[1] == 'r')
						*d++ = '\r';
					else if (s[1] == 't')
						*d++ = '\t';
					else
						*d++ = s[1];
					s += 2;
				} else {
					*d++ = *s++;
				}
			}
			if (*s == '"')
				s++; // go past closing quote
		}
	}

	*d++ = '\0';
	return start;
}
