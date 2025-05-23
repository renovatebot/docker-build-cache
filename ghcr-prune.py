#!/usr/bin/python3
# PYTHON_ARGCOMPLETE_OK
import argparse
import getpass
import os
import requests
from datetime import datetime, timedelta

__author__ = "Fiona Klute"
__version__ = "0.1"
__copyright__ = "Copyright (C) 2021 Fiona Klute"
__license__ = "MIT"
# https://github.com/airtower-luna/hello-ghcr/blob/main/ghcr-prune.py

# GitHub API documentation: https://docs.github.com/en/rest/reference/packages
github_api_accept = 'application/vnd.github.v3+json'
# https://docs.github.com/en/rest/overview/api-versions?apiVersion=2022-11-28
github_api_version = '2022-11-28'


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description='List versions of a GHCR container image you own, and '
        'optionally delete (prune) old, untagged versions.')
    parser.add_argument('--token', '-t', action='store_true',
                        help='ask for token input instead of using the '
                        'GHCR_TOKEN environment variable')
    parser.add_argument('--container', default='hello-ghcr-meow',
                        help='name of the container image')
    parser.add_argument('--verbose', '-v', action='store_true',
                        help='print extra debug info')
    parser.add_argument('--prune-age', type=float, metavar='DAYS',
                        default=None,
                        help='delete untagged images older than DAYS days')
    parser.add_argument('--dry-run', '-n', action='store_true',
                        help='do not actually prune images, just list which '
                        'would be pruned')

    # enable bash completion if argcomplete is available
    try:
        import argcomplete
        argcomplete.autocomplete(parser)
    except ImportError:
        pass

    args = parser.parse_args()

    if args.token:
        token = getpass.getpass('Enter Token: ')
    elif 'GHCR_TOKEN' in os.environ:
        token = os.environ['GHCR_TOKEN']
    else:
        raise ValueError('missing authentication token')

    s = requests.Session()
    s.headers.update({'Authorization': f'token {token}',
                      'Accept': github_api_accept,
                      'X-GitHub-Api-Version': github_api_version})

    del_before = datetime.now().astimezone() - timedelta(days=args.prune_age) \
        if args.prune_age is not None else None
    if del_before:
        print(f'Pruning images created before {del_before}')

    list_url: str | None = 'https://api.github.com/user/packages/' \
        f'container/{args.container}/versions?per_page=100'

    while list_url is not None:
        r = s.get(list_url)
        if 'link' in r.headers and 'next' in r.links:
            list_url = r.links['next']['url']
            if args.verbose:
                print(f'More result pages, next is <{list_url}>')
        else:
            list_url = None

        versions = r.json()
        if args.verbose:
            reset = datetime.fromtimestamp(int(r.headers["x-ratelimit-reset"]))
            print(f'{r.headers["x-ratelimit-remaining"]} requests remaining '
                  f'until {reset}')
            print(versions)

        for v in versions:
            try:
                print(f'{v["id"]}\t{v["name"]}\t{v['created_at']}')
                metadata = v["metadata"]["container"]
                # print(f'{v["id"]}\t{v["name"]}\t{v['created_at']}\t{metadata["tags"]}')
                created = datetime.fromisoformat(v['created_at'])

                # prune old untagged images if requested
                if del_before is not None and created < del_before \
                   and len(metadata['tags']) == 0:
                    if args.dry_run:
                        print(f'would delete {v["id"]}')
                    else:
                        r = s.delete(
                            'https://api.github.com/user/packages/'
                            f'container/{args.container}/versions/{v["id"]}')
                        r.raise_for_status()
                        print(f'deleted {v["id"]}')
                    
            except Exception as X:
                print(f'unexpected error\n{v}\n{X}')
                pass