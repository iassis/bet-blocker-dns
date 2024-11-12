# Define the input and output file paths
input_file = '/usr/local/bin/blocks.txt'
output_file = '/opt/unbound/etc/unbound/a-records.conf'

def generate_unbound_conf(input_file, output_file):
    with open(input_file, 'r') as f:
        domains = f.readlines()

    with open(output_file, 'w') as f:
        for domain in domains:
            domain = domain.strip()
            if domain:
                # Remove spaces from the domain
                domain = domain.replace(" ", "")
                f.write(f'local-zone: "{domain}" redirect\n')
                f.write(f'local-data: "{domain} A 0.0.0.0"\n\n')

if __name__ == '__main__':
    generate_unbound_conf(input_file, output_file)